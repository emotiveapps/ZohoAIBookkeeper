import Testing
@testable import BookkeeperCore

@Suite("BookkeeperCore Tests")
struct BookkeeperCoreTests {

    @Test("TransactionType has correct display names")
    func transactionTypeDisplayNames() {
        #expect(TransactionType.expense.displayName == "Expense")
        #expect(TransactionType.transfer.displayName == "Transfer")
        #expect(TransactionType.sale.displayName == "Sale")
    }

    @Test("TransactionType debit types excludes sales")
    func debitTypesExcludesSales() {
        let debitTypes = TransactionType.debitTypes
        #expect(!debitTypes.contains(.sale))
        #expect(debitTypes.contains(.expense))
    }

    @Test("TransactionType credit types excludes expense")
    func creditTypesExcludesExpense() {
        let creditTypes = TransactionType.creditTypes
        #expect(!creditTypes.contains(.expense))
        #expect(creditTypes.contains(.sale))
    }
}
