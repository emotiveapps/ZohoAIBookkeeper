import Foundation

// MARK: - Full Configuration

public struct FullConfiguration: Codable, Sendable {
    public let zoho: ZohoConfiguration
    public let anthropic: AnthropicConfiguration
    public let categoryMapping: CategoryMappingConfig?

    public init(
        zoho: ZohoConfiguration,
        anthropic: AnthropicConfiguration,
        categoryMapping: CategoryMappingConfig? = nil
    ) {
        self.zoho = zoho
        self.anthropic = anthropic
        self.categoryMapping = categoryMapping
    }

    /// URL of a transaction in the Zoho Books web UI (used by "view on web" affordances).
    public func transactionURL(bankAccountId: String, transactionId: String, isDebit: Bool) -> URL? {
        // Zoho Books is an SPA: the query string lives inside the URL fragment.
        let txnGroup = isDebit ? "money_out" : "money_in"
        let fragment = "/banking/transactions/details"
            + "?account_id=\(bankAccountId)"
            + "&bankaccount_id=\(bankAccountId)"
            + "&transaction_id=\(transactionId)"
            + "&filter_by=Status.Uncategorized"
            + "&txn_group=\(txnGroup)"
            + "&txn_status=uncategorized"
        return URL(string: "https://books.zoho.com/app/\(zoho.organizationId)#\(fragment)")
    }
}

// MARK: - Configuration Types

public struct ZohoConfiguration: Codable, Sendable {
    public let clientId: String
    public let clientSecret: String
    public var accessToken: String
    public var refreshToken: String
    public let organizationId: String
    public let region: String

    public init(
        clientId: String,
        clientSecret: String,
        accessToken: String,
        refreshToken: String,
        organizationId: String,
        region: String
    ) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.organizationId = organizationId
        self.region = region
    }

    public var baseURL: String {
        switch region.lowercased() {
        case "eu":
            return "https://www.zohoapis.eu/books/v3"
        case "in":
            return "https://www.zohoapis.in/books/v3"
        case "au":
            return "https://www.zohoapis.com.au/books/v3"
        default:
            return "https://www.zohoapis.com/books/v3"
        }
    }

    public var oauthURL: String {
        switch region.lowercased() {
        case "eu":
            return "https://accounts.zoho.eu/oauth/v2/token"
        case "in":
            return "https://accounts.zoho.in/oauth/v2/token"
        case "au":
            return "https://accounts.zoho.com.au/oauth/v2/token"
        default:
            return "https://accounts.zoho.com/oauth/v2/token"
        }
    }
}

public struct AnthropicConfiguration: Codable, Sendable {
    public let apiKey: String

    public init(apiKey: String) {
        self.apiKey = apiKey
    }
}

public struct CategoryMappingConfig: Codable, Sendable {
    public let categories: [CategoryConfig]

    public init(categories: [CategoryConfig]) {
        self.categories = categories
    }

    public var allCategoryNames: [String] {
        categories.flatMap { category -> [String] in
            var names = [category.name]
            if let children = category.children {
                names.append(contentsOf: children)
            }
            return names
        }
    }
}

public struct CategoryConfig: Codable, Sendable {
    public let name: String
    public let children: [String]?

    public init(name: String, children: [String]? = nil) {
        self.name = name
        self.children = children
    }
}

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
