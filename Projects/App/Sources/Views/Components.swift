import SwiftUI
import ZohoBooksClient
import BookkeeperCore

/// Small dashboard statistic.
struct StatTile: View {
    let title: String
    let value: Int
    let tint: Color

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title3.weight(.bold))
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// AI confidence pill, same thresholds as the CLI (≥80 green, ≥50 orange, else red).
struct ConfidenceBadge: View {
    let confidence: Int

    private var color: Color {
        confidence >= 80 ? .green : confidence >= 50 ? .orange : .red
    }

    var body: some View {
        Text("\(confidence)%")
            .font(.caption.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

/// The transaction being reviewed: amount (tinted by user-perspective direction),
/// date, payee/description, reference.
struct TransactionHeaderCard: View {
    let transaction: ZBBankTransaction
    let accountType: String

    private var isExpense: Bool {
        TransactionType.isUserExpense(isDebit: transaction.isDebit, accountType: accountType)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(transaction.displayAmount)
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(isExpense ? Color.red : Color.green)
                Spacer()
                Text(transaction.date)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(transaction.displayDescription)
                .font(.body)
                .lineLimit(3)

            if let reference = transaction.referenceNumber, !reference.isEmpty {
                Text("Ref \(reference)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}
