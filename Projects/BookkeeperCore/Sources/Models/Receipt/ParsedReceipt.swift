import Foundation


/// Fields Claude extracts from a receipt file.
public struct ParsedReceipt: Codable, Sendable, Equatable {
    public var vendor: String?
    /// yyyy-MM-dd
    public var date: String?
    public var total: Double?
    public var currency: String?
    public var cardLast4: String?
    public var confidence: Int
    public var notes: String?

    public init(
        vendor: String? = nil,
        date: String? = nil,
        total: Double? = nil,
        currency: String? = nil,
        cardLast4: String? = nil,
        confidence: Int = 0,
        notes: String? = nil
    ) {
        self.vendor = vendor
        self.date = date
        self.total = total
        self.currency = currency
        self.cardLast4 = cardLast4
        self.confidence = confidence
        self.notes = notes
    }
}

