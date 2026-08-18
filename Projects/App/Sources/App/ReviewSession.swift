import Foundation
import Observation
import ZohoBooksClient
import BookkeeperCore

/// Per-account triage queue: uncategorized transactions, one-ahead suggestion
/// prefetch, the editable draft for the current transaction, and Save/Skip.
@MainActor
@Observable
public final class ReviewSession {
    public enum State: Equatable {
        case loading
        case reviewing
        case finished
        case failed(String)
    }

    /// A transaction whose AI suggestion has been resolved (or degraded gracefully).
    struct Prepared {
        var draft: CategorizedTransaction
        var historyNotes: [String]
    }

    public let account: ZBBankAccount

    public private(set) var state: State = .loading
    public private(set) var queue: [ZBBankTransaction] = []
    public private(set) var position = 0
    public private(set) var isPreparing = false
    public private(set) var isSaving = false
    public private(set) var historyNotes: [String] = []
    public var draft: CategorizedTransaction?
    public var errorMessage: String?

    /// Counts for the end-of-queue summary.
    public private(set) var savedCount = 0
    public private(set) var skippedCount = 0
    public private(set) var deletedCount = 0

    private let workspace: Workspace
    private var prefetchTask: Task<Prepared, Never>?
    private var prefetchedTransactionId: String?
    private var loadGeneration = 0
    private var presentGeneration = 0

    /// Drafts (with any user edits) for transactions already visited this
    /// session, so back/forward navigation is instant and never re-calls Claude.
    private var preparedByTransactionId: [String: Prepared] = [:]

    public init(workspace: Workspace, account: ZBBankAccount) {
        self.workspace = workspace
        self.account = account
    }

    public var totalCount: Int { queue.count }

    public var availableTypes: [TransactionType] {
        guard let draft else { return [] }
        return TransactionType.availableTypes(
            isDebit: draft.transaction.isDebit,
            accountType: account.accountType
        )
    }

    public var zohoURL: URL? {
        guard let draft else { return nil }
        return workspace.configuration.transactionURL(
            bankAccountId: account.accountId,
            transactionId: draft.transaction.transactionId,
            isDebit: draft.transaction.isDebit
        )
    }

    public func start() async {
        loadGeneration += 1
        let generation = loadGeneration
        state = .loading
        do {
            let all = try await workspace.client.fetchUncategorizedTransactions(
                accountId: account.accountId,
                year: nil
            )
            guard generation == loadGeneration else { return }
            queue = await filterUnprocessed(all)
            position = 0
            guard !queue.isEmpty else {
                state = .finished
                return
            }
            state = .reviewing
            await present(index: 0)
        } catch {
            guard generation == loadGeneration else { return }
            // SwiftUI cancels the `.task` mid-navigation-transition and re-runs it
            // on re-attach; a cancelled load is superseded, not failed.
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                state = .loading
            } else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Re-run the AI suggestion for the current transaction on demand.
    public func regenerateSuggestion() async {
        guard let current = currentTransaction else { return }
        isPreparing = true
        let prepared = await prepare(current)
        apply(prepared)
        isPreparing = false
    }

    public func save() async {
        guard var draft, !isSaving else { return }

        // A draft whose type ended up as "skip" is just a skip.
        if draft.selectedType == .skip {
            await skip()
            return
        }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        // Empty vendor strings should not create empty Zoho contacts.
        draft.vendorName = draft.vendorName.trimmingCharacters(in: .whitespaces)

        do {
            let vendorUsed = try await workspace.categorizer.categorize(draft)
            if let cache = workspace.cache {
                await cache.markProcessed(draft.transaction.transactionId)
                if let vendorUsed {
                    await cache.addVendor(vendorUsed)
                }
                try? await cache.save()
            }
            if let vendorUsed {
                workspace.noteVendor(vendorUsed)
            }
            savedCount += 1
            workspace.adjustPendingCount(accountId: account.accountId, by: -1)
            await workspace.refreshCacheStats()
            await removeCurrentAndPresentNext()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func skip() async {
        guard let draft, !isSaving else { return }
        if let cache = workspace.cache {
            await cache.markSkipped(draft.transaction.transactionId)
            try? await cache.save()
        }
        skippedCount += 1
        workspace.adjustPendingCount(accountId: account.accountId, by: -1)
        await workspace.refreshCacheStats()
        await removeCurrentAndPresentNext()
    }

    /// Exclude the current transaction in Zoho Books (duplicates, noise).
    /// Zoho keeps it under the Excluded filter, so this is recoverable there.
    public func delete() async {
        guard let draft, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            try await workspace.client.excludeTransaction(
                transactionId: draft.transaction.transactionId
            )
            deletedCount += 1
            workspace.adjustPendingCount(accountId: account.accountId, by: -1)
            await workspace.refreshCacheStats()
            await removeCurrentAndPresentNext()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Navigation

    public var canGoBack: Bool { position > 0 }
    public var canGoForward: Bool { position + 1 < queue.count }

    public func goBack() async {
        guard canGoBack, !isSaving else { return }
        await present(index: position - 1)
    }

    public func goForward() async {
        guard canGoForward, !isSaving else { return }
        await present(index: position + 1)
    }

    /// Jump straight to a queue entry (from the queue list sheet).
    public func jump(to index: Int) async {
        guard queue.indices.contains(index), index != position, !isSaving else { return }
        await present(index: index)
    }

    // MARK: - Queue mechanics

    private var currentTransaction: ZBBankTransaction? {
        queue.indices.contains(position) ? queue[position] : nil
    }

    private func present(index: Int) async {
        // Keep the outgoing draft (with any user edits) so navigating back is
        // instant and free.
        if let draft {
            preparedByTransactionId[draft.transaction.transactionId] =
                Prepared(draft: draft, historyNotes: historyNotes)
        }

        presentGeneration += 1
        let generation = presentGeneration

        position = index
        guard let tx = currentTransaction else {
            state = .finished
            return
        }

        isPreparing = true
        draft = nil
        historyNotes = []
        errorMessage = nil

        let prepared: Prepared
        if let cached = preparedByTransactionId[tx.transactionId] {
            prepared = cached
        } else if let prefetchTask, prefetchedTransactionId == tx.transactionId {
            prepared = await prefetchTask.value
            self.prefetchTask = nil
            self.prefetchedTransactionId = nil
        } else {
            prepared = await prepare(tx)
        }
        // A newer present() superseded this one while we awaited.
        guard generation == presentGeneration else { return }
        apply(prepared)
        isPreparing = false

        prefetchNext()
    }

    /// After Save/Skip the record leaves the queue entirely; the next one
    /// slides into the same position.
    private func removeCurrentAndPresentNext() async {
        guard queue.indices.contains(position) else { return }
        preparedByTransactionId[queue[position].transactionId] = nil
        queue.remove(at: position)
        // Clear before present() so the departed record isn't stashed back
        // into the navigation cache.
        draft = nil
        guard !queue.isEmpty else {
            state = .finished
            return
        }
        await present(index: min(position, queue.count - 1))
    }

    private func prefetchNext() {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchedTransactionId = nil
        let nextIndex = position + 1
        guard queue.indices.contains(nextIndex) else { return }
        let next = queue[nextIndex]
        // Already visited: its draft is cached, nothing to prefetch.
        guard preparedByTransactionId[next.transactionId] == nil else { return }
        prefetchedTransactionId = next.transactionId
        prefetchTask = Task { [weak self] in
            guard let self else {
                return Prepared(
                    draft: CategorizedTransaction(transaction: next, suggestion: TransactionSuggestion()),
                    historyNotes: []
                )
            }
            return await self.prepare(next)
        }
    }

    private func apply(_ prepared: Prepared) {
        var prepared = prepared
        // The AI can suggest a type that isn't valid for this direction
        // (e.g. .refund on a credit-card credit); an out-of-list selection
        // renders the type picker blank. Clamp to .skip — valid for both
        // directions, and Save-as-skip never writes to Zoho.
        let types = TransactionType.availableTypes(
            isDebit: prepared.draft.transaction.isDebit,
            accountType: account.accountType
        )
        if !types.contains(prepared.draft.selectedType) {
            prepared.draft.selectedType = .skip
        }
        draft = prepared.draft
        historyNotes = prepared.historyNotes
    }

    /// Fetch the AI suggestion + history refinement; degrade to a manual draft on failure.
    private func prepare(_ transaction: ZBBankTransaction) async -> Prepared {
        do {
            let result = try await workspace.pipeline.suggestion(
                for: transaction,
                client: workspace.client,
                bankAccounts: workspace.bankAccounts,
                existingVendors: workspace.vendors,
                accountType: account.accountType
            )
            return Prepared(
                draft: CategorizedTransaction(transaction: transaction, suggestion: result.suggestion),
                historyNotes: result.debugLines
            )
        } catch {
            let fallback = TransactionSuggestion(
                transactionType: defaultType(for: transaction),
                category: "Uncategorized",
                confidence: 0,
                reasoning: "AI suggestion unavailable: \(error.localizedDescription)"
            )
            return Prepared(
                draft: CategorizedTransaction(transaction: transaction, suggestion: fallback),
                historyNotes: []
            )
        }
    }

    private func defaultType(for transaction: ZBBankTransaction) -> TransactionType {
        TransactionType.isUserExpense(isDebit: transaction.isDebit, accountType: account.accountType)
            ? .expense
            : .sale
    }

    private func filterUnprocessed(_ transactions: [ZBBankTransaction]) async -> [ZBBankTransaction] {
        guard let cache = workspace.cache else { return transactions }
        var result: [ZBBankTransaction] = []
        for tx in transactions {
            let processed = await cache.isProcessed(tx.transactionId)
            let skipped = await cache.isSkipped(tx.transactionId)
            if !processed && !skipped { result.append(tx) }
        }
        return result
    }
}
