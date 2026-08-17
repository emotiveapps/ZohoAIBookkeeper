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

/// The sidecar record stored next to each archived receipt file. The archive
/// (file + sidecar) is the durable audit trail, independent of Zoho.
public struct ReceiptRecord: Codable, Sendable {
    public struct Source: Codable, Sendable {
        /// "email" today; "share-extension" etc. later.
        public var kind: String
        public var mailbox: String?
        /// Graph message ID (immutable format), used for mailbox operations (moves).
        public var messageId: String?
        /// RFC 822 Message-ID header — the durable dedupe key (Graph IDs can drift).
        public var internetMessageId: String?
        public var subject: String?
        public var from: String?
        public var receivedAt: Date?

        public init(
            kind: String,
            mailbox: String? = nil,
            messageId: String? = nil,
            internetMessageId: String? = nil,
            subject: String? = nil,
            from: String? = nil,
            receivedAt: Date? = nil
        ) {
            self.kind = kind
            self.mailbox = mailbox
            self.messageId = messageId
            self.internetMessageId = internetMessageId
            self.subject = subject
            self.from = from
            self.receivedAt = receivedAt
        }
    }

    public var id: String
    /// Path of the receipt file relative to the archive root (e.g. "2026/2026-08-12-amazon-1a2b3c4d.pdf").
    public var relativePath: String
    public var source: Source
    public var parsed: ParsedReceipt?
    public var status: ReceiptStatus
    public var matchedExpenseId: String?
    public var attachedToZoho: Bool
    /// Candidate expense IDs when status is `.ambiguous`.
    public var candidateExpenseIds: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        relativePath: String,
        source: Source,
        parsed: ParsedReceipt? = nil,
        status: ReceiptStatus = .pending,
        matchedExpenseId: String? = nil,
        attachedToZoho: Bool = false,
        candidateExpenseIds: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.relativePath = relativePath
        self.source = source
        self.parsed = parsed
        self.status = status
        self.matchedExpenseId = matchedExpenseId
        self.attachedToZoho = attachedToZoho
        self.candidateExpenseIds = candidateExpenseIds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
