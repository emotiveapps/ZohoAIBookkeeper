import Foundation
import Security


public enum GraphError: LocalizedError, Sendable {
    case notSignedIn(mailbox: String)
    case authorizationDeclined
    case deviceCodeExpired
    case tokenRequestFailed(String)
    case requestFailed(status: Int, body: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case let .notSignedIn(mailbox):
            return "Not signed in for \(mailbox). Run `zoho-bookkeeper receipts login` first."
        case .authorizationDeclined:
            return "Sign-in was declined."
        case .deviceCodeExpired:
            return "The sign-in code expired before it was used. Run login again."
        case let .tokenRequestFailed(message):
            return "Microsoft sign-in failed: \(message)"
        case let .requestFailed(status, body):
            return "Microsoft Graph error (\(status)): \(body.prefix(300))"
        case .invalidResponse:
            return "Unexpected response from Microsoft Graph."
        }
    }
}

