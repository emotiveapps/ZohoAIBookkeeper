import Foundation


public enum ReceiptStatus: String, Codable, Sendable {
    /// No matching Zoho expense yet — retried on every sync.
    case pending
    /// Multiple plausible expenses — needs a human decision (`receipts attach`).
    case ambiguous
    /// Attached to a Zoho expense.
    case matched
    /// Deliberately ignored (not a receipt / duplicate).
    case skipped
}

