import Foundation

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
