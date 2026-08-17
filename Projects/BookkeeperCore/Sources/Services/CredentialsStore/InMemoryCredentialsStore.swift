import Foundation
import Security


/// Non-persistent store for previews and tests.
public final class InMemoryCredentialsStore: CredentialsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: FullConfiguration?

    public init(initial: FullConfiguration? = nil) {
        stored = initial
    }

    public func load() throws -> FullConfiguration? {
        lock.withLock { stored }
    }

    public func save(_ configuration: FullConfiguration) throws {
        lock.withLock { stored = configuration }
    }

    public func clear() throws {
        lock.withLock { stored = nil }
    }
}

