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

/// Receipt archive + triage: share-queue processing, pending retries, and
/// one-tap resolution of ambiguous matches.
struct ReceiptsView: View {
    let workspace: Workspace

    @Environment(\.dismiss) private var dismiss
    @State private var model: ReceiptsModel?
    @State private var resolving: ReceiptRecord?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Receipts")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if model == nil {
                    let newModel = ReceiptsModel(workspace: workspace)
                    model = newModel
                    await newModel.refresh()
                    await newModel.processQueue()
                }
            }
            .sheet(item: $resolving) { record in
                if let model {
                    CandidatePickerSheet(model: model, record: record)
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ model: ReceiptsModel) -> some View {
        List {
            if model.queueCount > 0 || model.isWorking || model.statusLine != nil {
                Section {
                    if model.isWorking {
                        HStack {
                            ProgressView().padding(.trailing, 8)
                            Text(model.statusLine ?? "Processing…")
                                .font(.callout)
                        }
                    } else if let status = model.statusLine {
                        Text(status).font(.callout).foregroundStyle(.secondary)
                    }
                    if model.queueCount > 0 && !model.isWorking {
                        Button("Process \(model.queueCount) shared item(s)") {
                            Task { await model.processQueue() }
                        }
                    }
                }
            }

            if !model.ambiguous.isEmpty {
                Section("Needs review") {
                    ForEach(model.ambiguous, id: \.id) { record in
                        Button {
                            resolving = record
                        } label: {
                            ReceiptRow(record: record)
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }

            if !model.pending.isEmpty {
                Section {
                    ForEach(model.pending, id: \.id) { record in
                        Button {
                            resolving = record
                        } label: {
                            ReceiptRow(record: record)
                        }
                        .foregroundStyle(.primary)
                    }
                    Button {
                        Task { await model.retryPending() }
                    } label: {
                        Label("Retry all pending", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isWorking)
                } header: {
                    Text("Pending (\(model.pending.count))")
                } footer: {
                    Text("Waiting for a matching expense in Zoho. Retried automatically on every sync; tap one to match it by hand.")
                }
            }

            Section("Matched (\(model.matched.count))") {
                ForEach(model.matched.prefix(50), id: \.id) { record in
                    ReceiptRow(record: record)
                }
            }
        }
        .refreshable {
            await model.refresh()
        }
        .overlay {
            if model.records.isEmpty && model.queueCount == 0 {
                ContentUnavailableView(
                    "No receipts yet",
                    systemImage: "doc.text.viewfinder",
                    description: Text("Share a receipt PDF or photo from any app via the share sheet, or forward receipt emails to your billing mailbox.")
                )
            }
        }
    }
}

private struct ReceiptRow: View {
    let record: ReceiptRecord

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.parsed?.vendor ?? record.source.subject ?? "Receipt")
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(record.parsed?.date ?? "no date")
                    Text(record.source.kind == "email" ? "✉️" : "📤")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let total = record.parsed?.total {
                Text(TaxReadinessReportFormatter.money(total))
                    .monospacedDigit()
            }
            if record.status == .matched {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }
}

/// Pick the expense a receipt belongs to.
private struct CandidatePickerSheet: View {
    let model: ReceiptsModel
    let record: ReceiptRecord

    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [ZBExpense]?

    var body: some View {
        NavigationStack {
            Group {
                if let candidates {
                    if candidates.isEmpty {
                        ContentUnavailableView(
                            "No candidate expenses",
                            systemImage: "magnifyingglass",
                            description: Text("No Zoho expenses near \(record.parsed?.date ?? "this receipt's date"). Categorize the transaction first, then retry.")
                        )
                    } else {
                        List(candidates, id: \.expenseId) { expense in
                            Button {
                                if let id = expense.expenseId {
                                    Task {
                                        await model.attach(record, to: id)
                                        dismiss()
                                    }
                                }
                            } label: {
                                LabeledContent {
                                    Text(TaxReadinessReportFormatter.money(expense.total ?? expense.amount ?? 0))
                                        .monospacedDigit()
                                } label: {
                                    Text(expense.vendorName ?? expense.accountName ?? "Expense")
                                    Text("\(expense.date ?? "") · \(expense.accountName ?? "")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                } else {
                    ProgressView("Finding candidates…")
                }
            }
            .navigationTitle(record.parsed?.vendor ?? "Match receipt")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                candidates = await model.candidates(for: record)
            }
        }
    }
}
