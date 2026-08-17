import Foundation

public struct AnthropicConfiguration: Codable, Sendable {
    public let apiKey: String

    public init(apiKey: String) {
        self.apiKey = apiKey
    }
}
