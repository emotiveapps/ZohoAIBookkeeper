import SwiftUI
import DesignSystem
import ZohoBooksClient

/// Zoho's "Match Transactions" flow: recorded transactions the current feed
/// line can be linked to instead of creating a new one. Tapping a candidate
/// performs the match and resolves the record.
struct MatchSheet: View {
    let session: ReviewSession

    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [ZBMatchingTransaction] = []
    @State private var loadError: String?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Asking Zoho for matches…")
                } else if let loadError {
                    ContentUnavailableView {
                        Label("Couldn't load matches", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(loadError)
                    }
                } else if candidates.isEmpty {
                    ContentUnavailableView {
                        Label("No matches", systemImage: "link.badge.plus")
                    } description: {
                        Text(
                            "Zoho has no recorded transaction that fits this one. "
                                + "If it's one side of a transfer or card payment, save the "
                                + "other side first — then this list will offer it."
                        )
                    }
                } else {
                    List(candidates, id: \.transactionId) { candidate in
                        Button {
                            dismiss()
                            Task { await session.match(candidate) }
                        } label: {
                            row(candidate)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Match Transactions")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            do {
                candidates = try await session.matchCandidates()
            } catch {
                loadError = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func row(_ candidate: ZBMatchingTransaction) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.transactionTypeFormatted ?? candidate.transactionType ?? "Transaction")
                    .font(.callout)
                Text(detailLine(candidate))
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            Spacer()
            if let amount = candidate.amount {
                Text(amount, format: .currency(code: "USD"))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }

    private func detailLine(_ candidate: ZBMatchingTransaction) -> String {
        var parts: [String] = []
        if let date = candidate.dateFormatted ?? candidate.date { parts.append(date) }
        if let contact = candidate.contactName, !contact.isEmpty { parts.append(contact) }
        if let reference = candidate.referenceNumber, !reference.isEmpty { parts.append("Ref \(reference)") }
        return parts.joined(separator: " · ")
    }
}
