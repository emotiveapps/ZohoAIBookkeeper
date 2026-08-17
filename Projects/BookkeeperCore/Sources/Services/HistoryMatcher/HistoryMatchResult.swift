import Foundation
import ZohoBooksClient

/// Result of history matching, including debug info for display
public struct HistoryMatchResult: Sendable {
    public let suggestion: TransactionSuggestion
    public let debugLines: [String]
}
