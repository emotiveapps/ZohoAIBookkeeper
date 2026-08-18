import Foundation
import Testing
import ZohoBooksClient
@testable import BookkeeperCore

/// These tests cover the categorizer's guard paths, which return before any
/// network call — so a real (unconfigured) client is safe to construct.
@Suite("TransactionCategorizer guards")
struct TransactionCategorizerTests {

    private func makeCategorizer() -> TransactionCategorizer {
        let config = ZohoConfig(
            clientId: "c", clientSecret: "s", accessToken: "a",
            refreshToken: "r", organizationId: "o", region: .com
        )
        return TransactionCategorizer(client: ZohoBooksClient(config: config))
    }

    private func draft(type: TransactionType, transferTo: String? = nil) -> CategorizedTransaction {
        let tx = ZBBankTransaction(transactionId: "tx1", date: "2026-08-01", amount: 10, debitOrCredit: "debit")
        var draft = CategorizedTransaction(
            transaction: tx,
            suggestion: TransactionSuggestion(transactionType: type)
        )
        draft.selectedType = type
        draft.transferToAccountId = transferTo
        return draft
    }

    @Test("Skip is refused, not silently accepted (B5)")
    func refusesNonWritableTypes() async {
        let categorizer = makeCategorizer()
        await #expect(throws: CategorizationError.self) {
            try await categorizer.categorize(draft(type: .skip))
        }
    }

    @Test("Transfer without a target account is rejected up front (B4)")
    func transferNeedsTarget() async {
        let categorizer = makeCategorizer()

        await #expect(throws: CategorizationError.self) {
            try await categorizer.categorize(draft(type: .transfer))
        }
        await #expect(throws: CategorizationError.self) {
            try await categorizer.categorize(draft(type: .transfer, transferTo: ""))
        }
    }

    @Test("Transfer whose transaction lacks its own account id is rejected up front")
    func transferNeedsSourceAccount() async {
        let categorizer = makeCategorizer()
        // draft() builds its transaction without an accountId, so this must
        // fail before any network call rather than send a one-sided transfer.
        await #expect(throws: CategorizationError.self) {
            try await categorizer.categorize(draft(type: .transfer, transferTo: "acc-2"))
        }
    }

    @Test("Categorization errors carry actionable messages")
    func errorMessages() {
        #expect(
            CategorizationError.accountNotFound(name: "Snacks").errorDescription?.contains("Snacks") == true
        )
        #expect(CategorizationError.transferTargetMissing.errorDescription?.isEmpty == false)
        #expect(
            CategorizationError.typeNotCategorizable(.skip).errorDescription?.contains("Skip") == true
        )
    }
}

@Suite("CategorizedTransaction defaults")
struct CategorizedTransactionTests {

    @Test("Draft fields fall back sensibly when the suggestion is sparse")
    func sparseSuggestion() {
        let tx = ZBBankTransaction(
            transactionId: "tx1", date: "2026-08-01", amount: 12.5,
            debitOrCredit: "debit", description: "CHECKCARD 1234 COFFEE"
        )
        let draft = CategorizedTransaction(transaction: tx, suggestion: TransactionSuggestion())

        #expect(draft.selectedType == .expense)
        #expect(draft.vendorName.isEmpty)
        #expect(draft.category == "Uncategorized")
        #expect(draft.description == "CHECKCARD 1234 COFFEE")
        #expect(draft.transferToAccountId == nil)
    }

    @Test("Suggestion values seed the editable fields")
    func populatedSuggestion() {
        let tx = ZBBankTransaction(transactionId: "tx1", date: "2026-08-01", amount: 5, debitOrCredit: "credit")
        let suggestion = TransactionSuggestion(
            transactionType: .sale,
            vendorName: "Acme",
            category: "Sales",
            description: "Customer payment",
            confidence: 88,
            reasoning: "-"
        )
        let draft = CategorizedTransaction(transaction: tx, suggestion: suggestion)

        #expect(draft.selectedType == .sale)
        #expect(draft.vendorName == "Acme")
        #expect(draft.category == "Sales")
        #expect(draft.description == "Customer payment")
    }
}
