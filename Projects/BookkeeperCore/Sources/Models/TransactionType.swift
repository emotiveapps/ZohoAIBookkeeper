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

    /// Transaction types available when money leaves the user's pocket
    public static var debitTypes: [TransactionType] {
        [.expense, .transfer, .skip]
    }

    /// Transaction types available when money comes back to the user —
    /// including refunds, which are returned expenses (on a credit card,
    /// Zoho reports these as debits because they reduce the liability)
    public static var creditTypes: [TransactionType] {
        [.sale, .refund, .transfer, .ownerContribution, .skip]
    }

    /// Returns the appropriate transaction types based on the transaction's debit/credit flag
    /// and the account type. Credit card accounts have inverted semantics:
    /// a "credit" on a credit card is an expense (purchase), not income.
    public static func availableTypes(isDebit: Bool, accountType: String) -> [TransactionType] {
        let isCreditCard = accountType.lowercased() == "credit_card"
        let isUserExpense = isCreditCard ? !isDebit : isDebit
        return isUserExpense ? debitTypes : creditTypes
    }

    /// Whether a transaction represents an expense from the user's perspective,
    /// accounting for credit card semantics.
    public static func isUserExpense(isDebit: Bool, accountType: String) -> Bool {
        let isCreditCard = accountType.lowercased() == "credit_card"
        return isCreditCard ? !isDebit : isDebit
    }
}
