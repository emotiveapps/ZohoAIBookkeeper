import Foundation
import Observation
import ZohoBooksClient
import BookkeeperCore

/// App lifecycle: credential loading, connection, and the active workspace.
@MainActor
@Observable
public final class AppModel {
    public enum Phase {
        case loading
        case needsSetup
        case ready(Workspace)
    }

    public private(set) var phase: Phase = .loading

    private let credentialsStore: any CredentialsStore

    public init(credentialsStore: any CredentialsStore = KeychainCredentialsStore()) {
        self.credentialsStore = credentialsStore
    }

    public var workspace: Workspace? {
        if case let .ready(workspace) = phase { return workspace }
        return nil
    }

    /// Called once at launch: restore credentials from the Keychain and connect.
    public func bootstrap() async {
        guard case .loading = phase else { return }

        let configuration: FullConfiguration?
        do {
            configuration = try credentialsStore.load()
        } catch {
            logger.error("Failed to read credentials: \(error)")
            configuration = nil
        }

        guard let configuration else {
            phase = .needsSetup
            return
        }

        // Enter the app immediately with saved credentials; data loads in the background
        // and any connection problem surfaces inside the workspace UI.
        let workspace = await Workspace.connect(configuration: configuration)
        phase = .ready(workspace)
        await workspace.refresh()
    }

    /// Validate new credentials by connecting; persist and switch phases only on success.
    /// - Returns: an error message to display, or nil on success.
    public func submitCredentials(_ configuration: FullConfiguration) async -> String? {
        let workspace = await Workspace.connect(configuration: configuration)
        await workspace.refresh()

        if workspace.bankAccounts.isEmpty, let error = workspace.lastError {
            return error
        }

        do {
            try credentialsStore.save(configuration)
        } catch {
            return "Connected, but saving to the Keychain failed: \(error.localizedDescription)"
        }

        phase = .ready(workspace)
        return nil
    }

    /// Forget credentials and return to setup. Local caches are left intact.
    public func signOut() {
        do {
            try credentialsStore.clear()
        } catch {
            logger.error("Failed to clear credentials: \(error)")
        }
        phase = .needsSetup
    }
}

/// A connected session: Zoho + Claude clients plus the reference data every screen needs.
@MainActor
@Observable
public final class Workspace {
    public let configuration: FullConfiguration
    public let client: ZohoBooksClient<ZohoOAuth>
    public let claudeService: ClaudeService
    public let pipeline: SuggestionPipeline
    public let categorizer: TransactionCategorizer
    public let cache: CacheService?

    public private(set) var bankAccounts: [ZBBankAccount] = []
    public private(set) var categories: [String] = []
    public private(set) var vendors: [String] = []
    public private(set) var pendingCounts: [String: Int] = [:]
    public private(set) var processedCount = 0
    public private(set) var skippedCount = 0
    public private(set) var isRefreshing = false
    public private(set) var lastError: String?

    public var categoryConfigs: [CategoryConfig] {
        configuration.categoryMapping?.categories ?? []
    }

    private init(configuration: FullConfiguration, client: ZohoBooksClient<ZohoOAuth>) {
        self.configuration = configuration
        self.client = client

        let categoryList = configuration.categoryMapping?.allCategoryNames ?? []
        self.claudeService = ClaudeService(
            apiKey: configuration.anthropic.apiKey,
            categories: categoryList,
            verbose: false
        )
        self.pipeline = SuggestionPipeline(claudeService: claudeService)
        self.categorizer = TransactionCategorizer(client: client)

        do {
            self.cache = try CacheService()
        } catch {
            logger.error("Cache unavailable: \(error)")
            self.cache = nil
        }
    }

    public static func connect(configuration: FullConfiguration) async -> Workspace {
        let zohoConfig = ZohoConfig(
            clientId: configuration.zoho.clientId,
            clientSecret: configuration.zoho.clientSecret,
            accessToken: configuration.zoho.accessToken,
            refreshToken: configuration.zoho.refreshToken,
            organizationId: configuration.zoho.organizationId,
            region: ZohoRegion(rawValue: configuration.zoho.region) ?? .com
        )
        let client = ZohoBooksClient(config: zohoConfig, verbose: false)
        await client.configure()
        return Workspace(configuration: configuration, client: client)
    }

    /// Load accounts, categories, vendors, pending counts, and cache stats.
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastError = nil
        defer { isRefreshing = false }

        do {
            bankAccounts = try await client.fetchBankAccounts()

            if let configured = configuration.categoryMapping?.allCategoryNames, !configured.isEmpty {
                categories = configured
            } else {
                let accounts = try await client.fetchAccounts()
                categories = accounts
                    .filter { ($0.accountType ?? "").lowercased() == "expense" }
                    .compactMap { $0.accountName }
                    .sorted()
            }

            let contacts = try await client.fetchContacts(contactType: "vendor")
            vendors = contacts.compactMap { $0.contactName }.sorted()

            await refreshPendingCounts()
        } catch {
            lastError = error.localizedDescription
        }

        await refreshCacheStats()
    }

    /// Recount uncategorized transactions per account (excluding locally processed/skipped).
    public func refreshPendingCounts() async {
        do {
            var counts: [String: Int] = [:]
            for account in bankAccounts {
                let transactions = try await client.fetchUncategorizedTransactions(
                    accountId: account.accountId,
                    year: nil
                )
                counts[account.accountId] = await unprocessedCount(in: transactions)
            }
            pendingCounts = counts
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func refreshCacheStats() async {
        guard let cache else { return }
        let stats = await cache.getStats()
        processedCount = stats.processed
        skippedCount = stats.skipped
    }

    public var totalPendingCount: Int {
        pendingCounts.values.reduce(0, +)
    }

    public func adjustPendingCount(accountId: String, by delta: Int) {
        pendingCounts[accountId] = max(0, (pendingCounts[accountId] ?? 0) + delta)
    }

    /// A vendor was just created/used; keep the in-session list current.
    public func noteVendor(_ name: String) {
        guard !name.isEmpty, !vendors.contains(name) else { return }
        vendors.append(name)
        vendors.sort()
    }

    private func unprocessedCount(in transactions: [ZBBankTransaction]) async -> Int {
        guard let cache else { return transactions.count }
        var count = 0
        for tx in transactions {
            let processed = await cache.isProcessed(tx.transactionId)
            let skipped = await cache.isSkipped(tx.transactionId)
            if !processed && !skipped { count += 1 }
        }
        return count
    }
}
