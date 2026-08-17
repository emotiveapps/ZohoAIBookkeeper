import Foundation

/// Loads and decodes the CLI's configuration from disk.
///
/// Search order:
/// 1. `$ZOHO_BOOKKEEPER_CONFIG` (explicit path — the installed CLI's wrapper
///    script sets this to the repo's config.json)
/// 2. `config.json` in the current directory or any ancestor (dev runs from
///    inside the repo)
///
/// Owner's policy: the config lives *in the repo*, gitignored — it survives
/// `just clean` and rebuilds, and dies with the repo. Never store it in a
/// home-directory dotfolder or bundle it as a resource (bundling once baked
/// real credentials into every built product, including iOS app bundles).
/// The iOS app stores credentials in the Keychain and never touches this loader.
public enum ConfigLoader {
    public static func load() throws -> FullConfiguration {
        let data = try Data(contentsOf: configURL())
        return try parse(data)
    }

    /// The resolved config.json location. Machine-local operational files
    /// (e.g. the CLI's sync state.json) live next to it in the repo.
    public static func configURL() throws -> URL {
        let candidates = candidatePaths()
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            let searched = candidates.map(\.path).joined(separator: "\n  ")
            throw ConfigurationError.fileNotFound(
                "config.json not found. Searched:\n  \(searched)\nCopy config.example.json there and fill in your credentials."
            )
        }
        return url
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
        // Walk up from the working directory so the CLI finds the repo's
        // config.json when run from the repo or any of its subdirectories.
        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0 ..< 8 {
            paths.append(directory.appendingPathComponent("config.json"))
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        #endif
        return paths
    }
}
