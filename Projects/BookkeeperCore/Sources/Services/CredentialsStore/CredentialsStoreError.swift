import Foundation
import Security


public enum CredentialsStoreError: LocalizedError {
    case keychainStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .keychainStatus(status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(message)"
        }
    }
}

