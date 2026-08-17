import SwiftUI
import Observation
import ZohoBooksClient
import BookkeeperCore


/// Drives the receipts screen: processes the share-extension queue, lists the
/// archive, retries pending matches, and resolves ambiguous ones.
@MainActor
@Observable
final class ReceiptsModel {
    private(set) var records: [ReceiptRecord] = []
    private(set) var queueCount = 0
    private(set) var isWorking = false
    private(set) var statusLine: String?

    private let workspace: Workspace

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    var pending: [ReceiptRecord] { records.filter { $0.status == .pending } }
    var ambiguous: [ReceiptRecord] { records.filter { $0.status == .ambiguous } }
    var matched: [ReceiptRecord] { records.filter { $0.status == .matched } }

    func refresh() async {
        guard let store = workspace.receiptStore else { return }
        records = await store.allRecords()
        queueCount = ShareInbox.pendingItems().count
    }

    /// Ingest everything the share extension has queued.
    func processQueue() async {
        guard let pipeline = workspace.receiptPipeline, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        for item in ShareInbox.pendingItems() {
            do {
                let data = try Data(contentsOf: item.fileURL)
                let result = try await pipeline.processLocalFile(
                    data: data,
                    contentType: item.contentType,
                    filename: item.originalName,
                    source: ReceiptRecord.Source(
                        kind: "share-extension",
                        subject: item.originalName,
                        receivedAt: item.sharedAt
                    )
                )
                statusLine = result.line
                ShareInbox.remove(item)
            } catch {
                statusLine = "Couldn't process \(item.originalName): \(error.localizedDescription)"
            }
        }
        await workspace.pushReceiptArchive()
        await refresh()
    }

    func retryPending() async {
        guard let pipeline = workspace.receiptPipeline, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let summary = try await pipeline.retryPending()
            statusLine = summary.retriedMatches > 0
                ? "Matched \(summary.retriedMatches) receipt(s)"
                : "No new matches yet"
        } catch {
            statusLine = error.localizedDescription
        }
        await workspace.pushReceiptArchive()
        await refresh()
    }

    func attach(_ record: ReceiptRecord, to expenseId: String) async {
        guard let pipeline = workspace.receiptPipeline else { return }
        do {
            try await pipeline.attach(record: record, expenseId: expenseId)
            statusLine = "Attached"
        } catch {
            statusLine = error.localizedDescription
        }
        await workspace.pushReceiptArchive()
        await refresh()
    }

    /// Candidate expenses to offer for a record (its stored candidates, or a
    /// date-window search for pending receipts).
    func candidates(for record: ReceiptRecord) async -> [ZBExpense] {
        var results: [ZBExpense] = []
        for id in record.candidateExpenseIds {
            if let expense = try? await workspace.client.fetchExpense(expenseId: id) {
                results.append(expense)
            }
        }
        if results.isEmpty, let dateString = record.parsed?.date,
           let anchor = GapDetector.parseDate(dateString) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")!
            formatter.dateFormat = "yyyy-MM-dd"
            let window: TimeInterval = 14 * 24 * 3600
            let expenses = (try? await workspace.client.fetchExpenses(
                dateStart: formatter.string(from: anchor.addingTimeInterval(-window)),
                dateEnd: formatter.string(from: anchor.addingTimeInterval(window))
            )) ?? []
            results = expenses
        }
        return results
    }
}

