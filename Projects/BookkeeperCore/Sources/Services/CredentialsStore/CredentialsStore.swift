import Foundation
import Security


/// Abstraction over credential persistence so views and tests don't touch the Keychain directly.
public protocol CredentialsStore: Sendable {
    func load() throws -> FullConfiguration?
    func save(_ configuration: FullConfiguration) throws
    func clear() throws
}

