import Foundation
import Testing
@testable import BookkeeperCore

@Suite("Vendor memory")
struct VendorMemoryTests {

    @Test("Normalizer strips the parts that vary per transaction")
    func normalizerKeys() {
        #expect(DescriptionNormalizer.key("INTEREST CHARGE:PURCHASES") == "INTEREST CHARGE PURCHASES")
        #expect(DescriptionNormalizer.key("UNITED xxxxxxxxx1291") == "UNITED XXXXXXXXX")
        #expect(
            DescriptionNormalizer.key("UNITED xxxxxxxxx1291")
                == DescriptionNormalizer.key("united XXXXXXXXX1285")
        )
        #expect(DescriptionNormalizer.key("1291") == nil)
        #expect(DescriptionNormalizer.key("AB") == nil)
    }

    @Test("Cache remembers and recalls vendors by description")
    func rememberAndRecall() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vendor-memory-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let cache = try CacheService(cacheDirectory: dir)
        await cache.rememberVendor("Chase", forDescription: "INTEREST CHARGE:PURCHASES")
        try await cache.save()

        let reloaded = try CacheService(cacheDirectory: dir)
        #expect(await reloaded.vendor(forDescription: "INTEREST CHARGE: PURCHASES") == "Chase")
        #expect(await reloaded.vendor(forDescription: "SOMETHING ELSE") == nil)
    }

    @Test("cache.json written before vendorByDescription existed still loads")
    func backwardCompatibleDecode() throws {
        let legacy = Data("""
        {"processedTransactions":["a"],"skippedTransactions":[],"knownVendors":["Amazon"]}
        """.utf8)
        let cache = try JSONDecoder().decode(TransactionCache.self, from: legacy)
        #expect(cache.processedTransactions == ["a"])
        #expect(cache.knownVendors == ["Amazon"])
        #expect(cache.vendorByDescription.isEmpty)
    }
}
