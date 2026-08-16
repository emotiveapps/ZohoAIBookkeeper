import Foundation
import Testing
@testable import BookkeeperCore

@Suite("CacheService")
struct CacheServiceTests {

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Round-trips processed, skipped, and vendors through disk")
    func roundTrip() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cache = try CacheService(cacheDirectory: dir)
        await cache.markProcessed("tx-1")
        await cache.markSkipped("tx-2")
        await cache.addVendor("Acme")
        try await cache.save()

        let reloaded = try CacheService(cacheDirectory: dir)
        #expect(await reloaded.isProcessed("tx-1"))
        #expect(await reloaded.isSkipped("tx-2"))
        #expect(!(await reloaded.isProcessed("tx-3")))
        #expect(await reloaded.getKnownVendors() == ["Acme"])

        let stats = await reloaded.getStats()
        #expect(stats.processed == 1)
        #expect(stats.skipped == 1)
        #expect(stats.vendors == 1)
    }

    @Test("Corrupt cache file starts fresh instead of crashing")
    func corruptFile() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("not json{{{".utf8).write(to: dir.appendingPathComponent("cache.json"))

        let cache = try CacheService(cacheDirectory: dir)
        #expect(!(await cache.isProcessed("anything")))
        let stats = await cache.getStats()
        #expect(stats.processed == 0)
    }

    @Test("Empty cache file starts fresh")
    func emptyFile() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data().write(to: dir.appendingPathComponent("cache.json"))

        let cache = try CacheService(cacheDirectory: dir)
        let stats = await cache.getStats()
        #expect(stats.processed == 0 && stats.skipped == 0 && stats.vendors == 0)
    }

    @Test("clear() wipes state and persists the wipe")
    func clear() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cache = try CacheService(cacheDirectory: dir)
        await cache.markProcessed("tx-1")
        try await cache.save()
        await cache.clear()
        try await cache.save()

        let reloaded = try CacheService(cacheDirectory: dir)
        #expect(!(await reloaded.isProcessed("tx-1")))
    }
}

@Suite("InMemoryCredentialsStore")
struct InMemoryCredentialsStoreTests {

    private var config: FullConfiguration {
        FullConfiguration(
            zoho: ZohoConfiguration(
                clientId: "id", clientSecret: "secret", accessToken: "at",
                refreshToken: "rt", organizationId: "org", region: "com"
            ),
            anthropic: AnthropicConfiguration(apiKey: "key")
        )
    }

    @Test("Save, load, and clear")
    func lifecycle() throws {
        let store = InMemoryCredentialsStore()
        #expect(try store.load() == nil)

        try store.save(config)
        #expect(try store.load()?.zoho.organizationId == "org")

        try store.clear()
        #expect(try store.load() == nil)
    }
}
