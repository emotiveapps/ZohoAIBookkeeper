import SwiftUI
import Observation
import ZohoBooksClient
import BookkeeperCore


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

