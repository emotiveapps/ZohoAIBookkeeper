import SwiftUI
import Observation
import ZohoBooksClient
import BookkeeperCore

/// Pick the expense a receipt belongs to.
struct CandidatePickerSheet: View {
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
