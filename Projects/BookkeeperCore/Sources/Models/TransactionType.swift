import Foundation

/// Transaction types for categorization
public enum TransactionType: String, CaseIterable, Codable, Sendable {
    case expense = "expense"
    case transfer = "transfer_fund"
    case ownerContribution = "owner_contribution"
    case sale = "sales_without_invoices"
    case refund = "refund"
    case skip = "skip"

    public var displayName: String {
        switch self {
        case .expense: return "Expense"
        case .transfer: return "Transfer"
        case .ownerContribution: return "Owner Contribution"
        case .sale: return "Sale"
        case .refund: return "Refund"
        case .skip: return "Skip"
        }
    }

    /// Transaction types available for debit transactions
    public static var debitTypes: [TransactionType] {
        [.expense, .transfer, .refund, .skip]
    }

    /// Transaction types available for credit transactions
    public static var creditTypes: [TransactionType] {
        [.sale, .transfer, .ownerContribution, .skip]
    }
}
