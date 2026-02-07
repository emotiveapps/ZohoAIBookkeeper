import Foundation
import ZohoBooksClient

/// Claude's suggestion for categorizing a bank transaction
public struct TransactionSuggestion: Codable, Sendable {
    /// The type of transaction (expense, transfer, sale, etc.)
    public let transactionType: TransactionType

    /// Suggested vendor name (for expenses)
    public let vendorName: String?

    /// Suggested expense category (Zoho account name)
    public let category: String?

    /// Suggested description for the transaction
    public let description: String?

    /// If this is a transfer, the target account name
    public let transferToAccount: String?

    /// Confidence level (0-100)
    public let confidence: Int

    /// Reasoning for the suggestion
    public let reasoning: String

    public init(
        transactionType: TransactionType = .expense,
        vendorName: String? = nil,
        category: String? = nil,
        description: String? = nil,
        transferToAccount: String? = nil,
        confidence: Int = 50,
        reasoning: String = ""
    ) {
        self.transactionType = transactionType
        self.vendorName = vendorName
        self.category = category
        self.description = description
        self.transferToAccount = transferToAccount
        self.confidence = confidence
        self.reasoning = reasoning
    }
}

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
