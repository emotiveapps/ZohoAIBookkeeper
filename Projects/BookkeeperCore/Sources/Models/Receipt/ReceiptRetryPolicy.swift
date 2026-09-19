import Foundation

/// Which pending receipts the hold-&-retry pass re-checks against Zoho.
///
/// The archive is the audit trail and is complete the moment a receipt is
/// filed — retrying only decides how long we keep hunting for the Zoho expense
/// to attach it to. Retrying without a budget is what made syncs slow: a
/// receipt whose expense was never recorded fails on every sync forever, at the
/// cost of one Zoho expense fetch each time. So the routine pass is budgeted,
/// and `.exhaustive` exists for the deliberate catch-up run after a backlog
/// import (scanned paper, a late statement).
public struct ReceiptRetryPolicy: Sendable, Equatable {
    /// Skip receipts older than this, measured from the receipt's own date.
    /// Nil retries at any age.
    public var maxAge: TimeInterval?

    /// Stop after this many unsuccessful passes. Nil never gives up.
    public var maxAttempts: Int?

    public init(maxAge: TimeInterval? = nil, maxAttempts: Int? = nil) {
        self.maxAge = maxAge
        self.maxAttempts = maxAttempts
    }

    /// The routine pass: recent receipts only, and only while there's a
    /// realistic chance the matching expense is still to arrive from the bank
    /// feed. Ninety days is past every feed's settlement lag with room to spare.
    public static let standard = ReceiptRetryPolicy(maxAge: 90 * 24 * 3600, maxAttempts: 5)

    /// Every pending receipt, regardless of age or how often it has failed.
    public static let exhaustive = ReceiptRetryPolicy()

    /// True when this policy retries everything — nothing is held back.
    public var isExhaustive: Bool { maxAge == nil && maxAttempts == nil }

    /// The date a receipt is aged from: its own date when parsed, else when it
    /// arrived, else when it was archived.
    static func effectiveDate(of record: ReceiptRecord) -> Date {
        record.parsed?.date.flatMap { GapDetector.parseDate($0) }
            ?? record.source.receivedAt
            ?? record.createdAt
    }

    /// Whether this pass should re-check `record`, given how many times it has
    /// already failed.
    public func allows(_ record: ReceiptRecord, attempts: Int, now: Date = Date()) -> Bool {
        if let maxAttempts, attempts >= maxAttempts { return false }
        if let maxAge, now.timeIntervalSince(Self.effectiveDate(of: record)) > maxAge { return false }
        return true
    }
}
