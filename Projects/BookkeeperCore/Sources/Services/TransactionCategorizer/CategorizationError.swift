import Foundation
import ZohoBooksClient

/// Errors surfaced when a categorization decision can't be written to Zoho.
/// These replace the old behavior of silently sending empty account IDs.
public enum CategorizationError: LocalizedError, Sendable {
    case accountNotFound(name: String)
    case transferTargetMissing
    case typeNotCategorizable(TransactionType)

    public var errorDescription: String? {
        switch self {
        case let .accountNotFound(name):
            return "No Zoho account named \"\(name)\" was found. Pick a different category or create the account in Zoho Books."
        case .transferTargetMissing:
            return "Select the account this transfer goes to."
        case let .typeNotCategorizable(type):
            return "\"\(type.displayName)\" can't be written to Zoho Books from this app."
        }
    }
}
