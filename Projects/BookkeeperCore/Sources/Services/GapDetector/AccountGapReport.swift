import Foundation
import ZohoBooksClient


/// Per-account gap analysis result.
public struct AccountGapReport: Sendable {
    public let accountId: String
    public let accountName: String
    public let transactionCount: Int
    public let firstDate: Date?
    public let lastDate: Date?
    /// Median days between consecutive transactions (nil when < 3 transactions).
    public let medianIntervalDays: Int?
    /// Transactions per week across the analyzed range, oldest week first (for sparklines).
    public let weeklyCounts: [Int]
    public let findings: [GapFinding]

    public var hasCriticalFindings: Bool {
        findings.contains { $0.severity == .critical }
    }
}

