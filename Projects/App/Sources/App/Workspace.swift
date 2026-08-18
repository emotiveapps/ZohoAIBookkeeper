import Foundation
import Observation
import ZohoBooksClient
import BookkeeperCore

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
    public let receiptStore: ReceiptStore?
    public let receiptPipeline: ReceiptPipeline?
    /// Graph client for the configured receipt mailbox (nil when receipts
    /// aren't configured). Sign-in state lives in this device's Keychain.
    public let graphMail: MicrosoftGraphMailClient?

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

        let graphMail = (configuration.receipts?.mailboxes.first).map { MicrosoftGraphMailClient(config: $0) }
        self.graphMail = graphMail

        do {
            let store: ReceiptStore
            if let graphMail, let receipts = configuration.receipts {
                // Cloud-canonical archive: purgeable cache in Caches,
                // pending uploads staged in Application Support.
                let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                let engine = try GraphDriveSyncEngine(
                    graph: graphMail,
                    folderPath: receipts.resolvedArchiveFolderPath,
                    cacheRoot: caches.appendingPathComponent("ReceiptsArchive"),
                    stagingRoot: support.appendingPathComponent("ArchiveStaging"),
                    syncState: UserDefaultsSyncState()
                )
                store = ReceiptStore(engine: engine)
            } else {
                // No Microsoft config: local-only archive in Documents.
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                store = try ReceiptStore(root: documents.appendingPathComponent("Receipts"))
            }
            self.receiptStore = store
            // With a Microsoft sign-in on this device the pipeline can sweep
            // the mailbox and OneDrive folder; without one it still processes
            // shared files and retries pendings.
            self.receiptPipeline = ReceiptPipeline(
                graph: graphMail,
                driveFolder: configuration.receipts?.onedrive?.folderPath,
                parser: ReceiptParser(apiKey: configuration.anthropic.apiKey),
                store: store,
                syncState: UserDefaultsSyncState(),
                zoho: client
            )
        } catch {
            logger.error("Receipt store unavailable: \(error)")
            self.receiptStore = nil
            self.receiptPipeline = nil
        }
    }

    /// Best-effort push of locally staged archive files to OneDrive (called
    /// after ingests/attaches; failures stay staged and retry next sync).
    public func pushReceiptArchive() async {
        guard let engine = await receiptStore?.syncEngine else { return }
        _ = try? await engine.push()
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
        let workspace = Workspace(configuration: configuration, client: client)
        workspace.refreshMicrosoftHealth()
        return workspace
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
                // Includes inventory/COGS accounts (LEGO resale purchases are
                // categorized as assets, not period expenses).
                categories = CategoryFilter.spendingCategories(from: accounts)
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
            WatchSync.shared.send(totalPending: totalPendingCount)
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
        WatchSync.shared.send(totalPending: totalPendingCount)
    }

    // MARK: - Connection health (Settings status rows)

    public enum ServiceHealth: Equatable {
        case checking
        case ok
        /// Configured, but not currently usable (reason shown to the user).
        case unavailable(String)
        case notConfigured
    }

    /// Derived from the reference-data load — no extra API calls.
    public var zohoHealth: ServiceHealth {
        if let lastError { return .unavailable(lastError) }
        if bankAccounts.isEmpty { return isRefreshing ? .checking : .unavailable("No accounts loaded yet") }
        return .ok
    }

    public private(set) var anthropicHealth: ServiceHealth = .checking

    /// One-token round trip; result is cached for the session once it succeeds.
    public func checkAnthropicHealth() async {
        if anthropicHealth == .ok { return }
        anthropicHealth = .checking
        if let error = await claudeService.ping() {
            anthropicHealth = .unavailable(error)
        } else {
            anthropicHealth = .ok
        }
    }

    /// Microsoft token presence on *this device*. Stored (not computed) so
    /// the UI actually re-renders when sign-in completes: Observation can't
    /// see Keychain writes, so callers refresh explicitly — on Settings
    /// appearance, when the sign-in sheet closes, and on app foreground.
    public private(set) var mailboxHealth: ServiceHealth = .notConfigured
    public private(set) var oneDriveHealth: ServiceHealth = .notConfigured

    public func refreshMicrosoftHealth() {
        guard let mailbox = configuration.receipts?.mailboxes.first else {
            mailboxHealth = .notConfigured
            oneDriveHealth = .notConfigured
            return
        }
        let signedIn = GraphTokenStore(mailbox: mailbox).load() != nil
        mailboxHealth = signedIn ? .ok : .unavailable("Not signed in on this device")
        oneDriveHealth = configuration.receipts?.onedrive == nil
            ? .notConfigured
            : (signedIn ? .ok : .unavailable("Not signed in on this device"))
    }

    // MARK: - Manual receipt sync (Settings → Maintenance)

    public enum ReceiptSyncStatus: Equatable {
        case idle
        case running
        case finished(String)
        case failed(String)
    }

    public private(set) var receiptSyncStatus: ReceiptSyncStatus = .idle
    public private(set) var lastReceiptSyncAt: Date? =
        UserDefaults.standard.object(forKey: "lastReceiptSyncAt") as? Date
    public private(set) var lastReceiptSyncResult: String? =
        UserDefaults.standard.string(forKey: "lastReceiptSyncResult")

    public var isSyncingReceipts: Bool { receiptSyncStatus == .running }

    /// Process the share-extension queue, sweep the receipt mailbox and
    /// OneDrive folder (when signed in on this device), then retry all pending
    /// receipts against Zoho — one retry pass total, since that's the
    /// API-heavy part and the reason the UI warns when re-triggered within
    /// 24 hours. State lives here (not on a screen) so Settings can be closed
    /// and revisited while a sync runs.
    public func syncReceiptsNow() async {
        guard !isSyncingReceipts, let receiptPipeline else { return }
        receiptSyncStatus = .running

        var sharedProcessed = 0
        var errors: [String] = []

        // Cloud-canonical archive: pull other devices' work first.
        if let engine = await receiptStore?.syncEngine {
            do {
                _ = try await engine.pull()
            } catch {
                errors.append("archive pull: \(error.localizedDescription)")
            }
        }

        for item in ShareInbox.pendingItems() {
            do {
                let data = try Data(contentsOf: item.fileURL)
                _ = try await receiptPipeline.processLocalFile(
                    data: data,
                    contentType: item.contentType,
                    filename: item.originalName,
                    source: ReceiptRecord.Source(
                        kind: "share-extension",
                        subject: item.originalName,
                        receivedAt: item.sharedAt
                    )
                )
                sharedProcessed += 1
                ShareInbox.remove(item)
            } catch {
                errors.append("\(item.originalName): \(error.localizedDescription)")
            }
        }

        var mailReceipts: Int?
        var driveReceipts: Int?
        if let graphMail, await graphMail.isSignedIn {
            do {
                let summary = try await receiptPipeline.sync(runRetryPass: false)
                mailReceipts = summary.newReceipts
                if summary.errors > 0 { errors.append("\(summary.errors) mailbox error(s)") }
            } catch {
                errors.append("mailbox: \(error.localizedDescription)")
            }
            if configuration.receipts?.onedrive != nil {
                do {
                    let summary = try await receiptPipeline.syncDrive(runRetryPass: false)
                    driveReceipts = summary.newReceipts
                    if summary.errors > 0 { errors.append("\(summary.errors) OneDrive error(s)") }
                } catch {
                    errors.append("OneDrive: \(error.localizedDescription)")
                }
            }
        }

        var retried = 0
        do {
            let summary = try await receiptPipeline.retryPending()
            retried = summary.retriedMatches
        } catch {
            errors.append(error.localizedDescription)
        }

        var archived = 0
        if let engine = await receiptStore?.syncEngine {
            do {
                let report = try await engine.push()
                archived = report.uploaded
                errors.append(contentsOf: report.warnings)
            } catch {
                errors.append("archive push: \(error.localizedDescription)")
            }
        }

        var parts: [String] = []
        if sharedProcessed > 0 { parts.append("\(sharedProcessed) shared file(s) processed") }
        if let mailReceipts { parts.append("\(mailReceipts) new from mail") }
        if let driveReceipts { parts.append("\(driveReceipts) new from OneDrive") }
        if archived > 0 { parts.append("\(archived) archived to OneDrive") }
        parts.append(retried > 0 ? "\(retried) pending receipt(s) matched" : "no new matches")
        if !errors.isEmpty { parts.append("\(errors.count) error(s)") }
        let line = parts.joined(separator: " · ")

        lastReceiptSyncAt = Date()
        lastReceiptSyncResult = line
        UserDefaults.standard.set(lastReceiptSyncAt, forKey: "lastReceiptSyncAt")
        UserDefaults.standard.set(line, forKey: "lastReceiptSyncResult")
        receiptSyncStatus = errors.isEmpty ? .finished(line) : .failed(line)
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
