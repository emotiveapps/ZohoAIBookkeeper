import Foundation
import Security


public struct GraphTokens: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    /// Refresh a minute early so an in-flight request can't race expiry.
    public func needsRefresh(now: Date = Date()) -> Bool {
        now >= expiresAt.addingTimeInterval(-60)
    }
}

