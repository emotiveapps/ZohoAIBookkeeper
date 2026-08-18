import SwiftUI
import DesignSystem
import ZohoBooksClient

/// The remaining review queue as a scannable list — date, payee/description,
/// amount, and source — for spotting duplicates side by side. Tapping a row
/// jumps the review session to that record.
struct QueueListSheet: View {
    let queue: [ZBBankTransaction]
    let position: Int
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Amount+direction pairs that appear more than once — the duplicate-suspect signal.
    private var repeatedAmountKeys: Set<String> {
        var counts: [String: Int] = [:]
        for tx in queue {
            counts[amountKey(tx), default: 0] += 1
        }
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(queue.enumerated()), id: \.element.transactionId) { index, tx in
                    Button {
                        onSelect(index)
                        dismiss()
                    } label: {
                        row(index: index, transaction: tx)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Queue (\(queue.count))")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(index: Int, transaction: ZBBankTransaction) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.displayDescription)
                    .font(.callout)
                    .lineLimit(2)
                Text(detailLine(transaction))
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(transaction.displayAmount)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                if repeatedAmountKeys.contains(amountKey(transaction)) {
                    Label("Same amount appears more than once", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                        .font(.caption2)
                        .foregroundStyle(Theme.Colors.warning)
                }
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(
            index == position ? Theme.Colors.accent.opacity(0.12) : nil
        )
    }

    private func detailLine(_ transaction: ZBBankTransaction) -> String {
        var parts = [transaction.date]
        if let reference = transaction.referenceNumber, !reference.isEmpty {
            parts.append("Ref \(reference)")
        }
        if let source = transaction.source, !source.isEmpty {
            parts.append(source)
        }
        return parts.joined(separator: " · ")
    }

    private func amountKey(_ transaction: ZBBankTransaction) -> String {
        "\(transaction.debitOrCredit)|\(transaction.amount)"
    }
}
