import Foundation
import ZohoBooksClient


/// A transaction with its suggested categorization for display/editing
public struct CategorizedTransaction: Sendable {
    public let transaction: ZBBankTransaction
    public var suggestion: TransactionSuggestion

    /// Editable fields
    public var selectedType: TransactionType
    public var vendorName: String
    public var category: String
    public var description: String
    public var transferToAccountId: String?

    public init(transaction: ZBBankTransaction, suggestion: TransactionSuggestion) {
        self.transaction = transaction
        self.suggestion = suggestion
        self.selectedType = suggestion.transactionType
        self.vendorName = suggestion.vendorName ?? ""
        self.category = suggestion.category ?? "Uncategorized"
        self.description = suggestion.description ?? transaction.description ?? ""
        self.transferToAccountId = nil
    }
}

