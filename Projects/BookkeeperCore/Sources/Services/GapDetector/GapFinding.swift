import Foundation
import ZohoBooksClient

/// A suspicious quiet period in an account's transaction feed.
public struct GapFinding: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// No transactions between two dates that both have activity around them.
        case silentWindow
        /// The feed goes quiet before the end of the analyzed range (possible dead feed).
        case staleFeed
        /// Activity starts suspiciously late in the analyzed range.
        case lateStart
    }

    public enum Severity: Sendable, Equatable, Comparable {
        case warning
        case critical
    }

    public let kind: Kind
    public let severity: Severity
    /// Last day with activity before the gap (or range start for `.lateStart`).
    public let start: Date
    /// First day with activity after the gap (or range end for `.staleFeed`).
    public let end: Date
    public let days: Int
    public let summary: String
}
