import Foundation


/// Model for cached transaction data
public struct TransactionCache: Codable, Sendable {
    public var processedTransactions: Set<String> = []
    public var skippedTransactions: Set<String> = []
    public var knownVendors: Set<String> = []

    public init() {}
}

