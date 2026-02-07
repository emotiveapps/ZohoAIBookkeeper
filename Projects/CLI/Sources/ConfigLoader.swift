import Foundation
import BookkeeperCore

/// Full configuration including file loading (CLI-specific)
public struct FullConfiguration: Codable {
    public let zoho: ZohoConfiguration
    public let anthropic: AnthropicConfiguration
    public let categoryMapping: CategoryMappingConfig?
}

/// Configuration file loader for CLI
public enum ConfigLoader {
    public static func load(from path: String) throws -> FullConfiguration {
        let url = URL(fileURLWithPath: path)

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConfigurationError.fileNotFound(path)
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        do {
            return try decoder.decode(FullConfiguration.self, from: data)
        } catch {
            throw ConfigurationError.invalidFormat(error.localizedDescription)
        }
    }
}
