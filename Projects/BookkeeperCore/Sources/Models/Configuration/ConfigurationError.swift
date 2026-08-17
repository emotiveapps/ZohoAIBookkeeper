import Foundation

public enum ConfigurationError: LocalizedError, Sendable {
    case fileNotFound(String)
    case invalidFormat(String)
    case missingField(String)

    public var errorDescription: String? {
        switch self {
        case let .fileNotFound(path):
            return "Configuration file not found at: \(path)"
        case let .invalidFormat(message):
            return "Invalid configuration format: \(message)"
        case let .missingField(field):
            return "Missing required field: \(field)"
        }
    }
}
