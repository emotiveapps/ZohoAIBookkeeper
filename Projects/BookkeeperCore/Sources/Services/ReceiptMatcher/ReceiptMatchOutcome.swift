import Foundation
import ZohoBooksClient


public enum ReceiptMatchOutcome: Sendable {
    /// Exactly one expense fits well enough to attach without asking.
    case confident(ZBExpense)
    /// More than one plausible expense — a human picks (`receipts attach`).
    case ambiguous([ZBExpense])
    /// Nothing fits yet — hold and retry after future syncs.
    case none
}

