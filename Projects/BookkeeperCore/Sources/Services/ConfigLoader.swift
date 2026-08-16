import Foundation

/// Loads and decodes the CLI's configuration from disk.
///
/// Search order:
/// 1. `$ZOHO_BOOKKEEPER_CONFIG` (explicit path)
/// 2. `~/.zoho-ai-bookkeeper/config.json`
///
/// The config used to be bundled into the framework as a resource, which baked
/// real credentials into every built product (including iOS app bundles). The
/// iOS app stores credentials in the Keychain and never touches this loader.
public enum ConfigLoader {
    public static func load() throws -> FullConfiguration {
        let candidates = candidatePaths()
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            let searched = candidates.map(\.path).joined(separator: "\n  ")
            throw ConfigurationError.fileNotFound(
                "config.json not found. Searched:\n  \(searched)\nCopy config.example.json there and fill in your credentials."
            )
        }

        let data = try Data(contentsOf: url)
        return try parse(data)
    }

    /// Decode a `config.json`-format payload (snake_case keys). Shared by the CLI's
    /// disk loading and the app's paste-to-import flow.
    public static func parse(_ data: Data) throws -> FullConfiguration {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        do {
            return try decoder.decode(FullConfiguration.self, from: data)
        } catch {
            throw ConfigurationError.invalidFormat(error.localizedDescription)
        }
    }

    private static func candidatePaths() -> [URL] {
        var paths: [URL] = []
        if let override = ProcessInfo.processInfo.environment["ZOHO_BOOKKEEPER_CONFIG"], !override.isEmpty {
            paths.append(URL(fileURLWithPath: override))
        }
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser
        paths.append(home.appendingPathComponent(".zoho-ai-bookkeeper/config.json"))
        #endif
        return paths
    }
}
