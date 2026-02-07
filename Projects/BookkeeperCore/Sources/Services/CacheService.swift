import Foundation

/// Service for caching processed transactions
public actor CacheService {
    private let cacheDirectory: URL
    private var cache: TransactionCache

    public init(cacheDirectory: URL? = nil) throws {
        if let dir = cacheDirectory {
            self.cacheDirectory = dir
        } else {
            #if os(macOS)
            let homeDir = FileManager.default.homeDirectoryForCurrentUser
            self.cacheDirectory = homeDir.appendingPathComponent(".zoho-ai-bookeeper")
            #else
            // iOS/watchOS: Use app's documents directory
            let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.cacheDirectory = documentsDir.appendingPathComponent("ZohoBookkeeperCache")
            #endif
        }

        // Create cache directory if needed
        try FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)

        // Load or create cache
        let cacheFile = self.cacheDirectory.appendingPathComponent("cache.json")
        if FileManager.default.fileExists(atPath: cacheFile.path) {
            do {
                let data = try Data(contentsOf: cacheFile)
                guard !data.isEmpty else {
                    logger.warning("Cache file is empty, starting fresh: \(cacheFile.path)")
                    self.cache = TransactionCache()
                    return
                }
                self.cache = try JSONDecoder().decode(TransactionCache.self, from: data)
            } catch {
                logger.error("Failed to load cache from \(cacheFile.path): \(error)")
                self.cache = TransactionCache()
            }
        } else {
            self.cache = TransactionCache()
        }
    }

    /// Check if a transaction has been processed
    public func isProcessed(_ transactionId: String) -> Bool {
        cache.processedTransactions.contains(transactionId)
    }

    /// Check if a transaction was skipped
    public func isSkipped(_ transactionId: String) -> Bool {
        cache.skippedTransactions.contains(transactionId)
    }

    /// Mark a transaction as processed
    public func markProcessed(_ transactionId: String) {
        cache.processedTransactions.insert(transactionId)
    }

    /// Mark a transaction as skipped
    public func markSkipped(_ transactionId: String) {
        cache.skippedTransactions.insert(transactionId)
    }

    /// Add a vendor to the cache for matching
    public func addVendor(_ vendorName: String) {
        cache.knownVendors.insert(vendorName)
    }

    /// Get all known vendors
    public func getKnownVendors() -> [String] {
        Array(cache.knownVendors).sorted()
    }

    /// Save the cache to disk
    public func save() throws {
        let cacheFile = cacheDirectory.appendingPathComponent("cache.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cache)
        try data.write(to: cacheFile)
    }

    /// Clear all cached data
    public func clear() {
        cache = TransactionCache()
    }

    /// Get cache statistics
    public func getStats() -> (processed: Int, skipped: Int, vendors: Int) {
        (
            processed: cache.processedTransactions.count,
            skipped: cache.skippedTransactions.count,
            vendors: cache.knownVendors.count
        )
    }
}

/// Model for cached transaction data
public struct TransactionCache: Codable, Sendable {
    public var processedTransactions: Set<String> = []
    public var skippedTransactions: Set<String> = []
    public var knownVendors: Set<String> = []

    public init() {}
}
