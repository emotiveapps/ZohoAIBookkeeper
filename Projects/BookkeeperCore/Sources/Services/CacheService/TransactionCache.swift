import Foundation

/// Model for cached transaction data
public struct TransactionCache: Codable, Sendable {
    public var processedTransactions: Set<String> = []
    public var skippedTransactions: Set<String> = []
    public var knownVendors: Set<String> = []
    /// Normalized feed description -> the vendor the user last saved for it.
    public var vendorByDescription: [String: String] = [:]

    public init() {}

    // Custom decoding so cache.json files written before a field existed
    // still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        processedTransactions = try container.decodeIfPresent(
            Set<String>.self, forKey: .processedTransactions) ?? []
        skippedTransactions = try container.decodeIfPresent(
            Set<String>.self, forKey: .skippedTransactions) ?? []
        knownVendors = try container.decodeIfPresent(
            Set<String>.self, forKey: .knownVendors) ?? []
        vendorByDescription = try container.decodeIfPresent(
            [String: String].self, forKey: .vendorByDescription) ?? [:]
    }
}
