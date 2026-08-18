import Foundation

/// Transaction types for categorization
public enum TransactionType: String, CaseIterable, Codable, Sendable {
    case expense = "expense"
    case transfer = "transfer_fund"
    case cardPayment = "card_payment"
    case ownerContribution = "owner_contribution"
    case sale = "sales_without_invoices"
    case refund = "refund"
    case skip = "skip"

    public var displayName: String {
        switch self {
        case .expense: return "Expense"
        case .transfer: return "Transfer"
        case .cardPayment: return "Card Payment"
        case .ownerContribution: return "Owner Contribution"
        case .sale: return "Sale"
        case .refund: return "Refund"
        case .skip: return "Skip"
        }
    }

    /// Transaction types available when money leaves the user's pocket —
    /// card payment here means paying a card's balance from this account
    public static var debitTypes: [TransactionType] {
        [.expense, .transfer, .cardPayment, .skip]
    }

    /// Transaction types available when money comes back to the user —
    /// including refunds, which are returned expenses (on a credit card,
    /// Zoho reports these as debits because they reduce the liability),
    /// and card payments arriving onto a card
    public static var creditTypes: [TransactionType] {
        [.sale, .refund, .transfer, .cardPayment, .ownerContribution, .skip]
    }

    /// Returns the appropriate transaction types based on the transaction's
    /// debit/credit flag.
    public static func availableTypes(isDebit: Bool, accountType: String) -> [TransactionType] {
        isUserExpense(isDebit: isDebit, accountType: accountType) ? debitTypes : creditTypes
    }

    /// Whether a transaction represents money leaving the user's pocket.
    ///
    /// Zoho reports `debit_or_credit` in ledger terms for *every* account
    /// type: debit = money arriving (asset increase on a bank account,
    /// liability decrease on a credit card), credit = money leaving. Verified
    /// against live data on both account types (Aug 2026): Stripe payouts and
    /// owner contributions into Checking are debits; card payments out of
    /// Checking and purchases on cards are credits. So the answer is simply
    /// `!isDebit`; `accountType` is kept for callers and in case a future
    /// Zoho surface isn't uniform.
    public static func isUserExpense(isDebit: Bool, accountType: String) -> Bool {
        !isDebit
    }
}
