import SwiftUI
import DesignSystem
import ZohoBooksClient
import BookkeeperCore

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
                    .font(Theme.Typography.amount)
                    .foregroundStyle(isExpense ? Theme.Colors.textPrimary : Theme.Colors.success)
                // Copies the bare number ("5.60") — matches both "$5.60" and
                // "5.60" when searching email for the receipt.
                CopyButton(
                    text: String(format: "%.2f", transaction.amount),
                    accessibilityLabel: "Copy amount"
                )
                Spacer()
                Text(transaction.date)
                    .font(.subheadline)
                    .foregroundStyle(Theme.Colors.textSecondary)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}
