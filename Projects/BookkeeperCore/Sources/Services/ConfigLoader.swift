import Foundation

/// Loads and decodes configuration from a bundled JSON file
public enum ConfigLoader {
    public static func load() throws -> FullConfiguration {
        guard let url = Bundle.module.url(forResource: "config", withExtension: "json") else {
            throw ConfigurationError.fileNotFound("config.json not found in bundle")
        }

        let data = try Data(contentsOf: url)
        return try parse(data)
    }

    /// Decode a `config.json`-format payload (snake_case keys). Shared by the CLI's
    /// bundled-config loading and the app's paste-to-import flow.
    public static func parse(_ data: Data) throws -> FullConfiguration {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        do {
            return try decoder.decode(FullConfiguration.self, from: data)
        } catch {
            throw ConfigurationError.invalidFormat(error.localizedDescription)
        }
    }
}
