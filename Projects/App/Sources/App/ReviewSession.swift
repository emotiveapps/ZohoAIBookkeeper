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

    private let workspace: Workspace
    private var prefetchTask: Task<Prepared, Never>?
    private var loadGeneration = 0

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
            await advance()
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
        await advance()
    }

    // MARK: - Queue mechanics

    private var currentTransaction: ZBBankTransaction? {
        queue.indices.contains(position) ? queue[position] : nil
    }

    private func present(index: Int) async {
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
        if let prefetchTask {
            prepared = await prefetchTask.value
            self.prefetchTask = nil
        } else {
            prepared = await prepare(tx)
        }
        apply(prepared)
        isPreparing = false

        prefetchNext()
    }

    private func advance() async {
        await present(index: position + 1)
    }

    private func prefetchNext() {
        prefetchTask?.cancel()
        prefetchTask = nil
        let nextIndex = position + 1
        guard queue.indices.contains(nextIndex) else { return }
        let next = queue[nextIndex]
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
