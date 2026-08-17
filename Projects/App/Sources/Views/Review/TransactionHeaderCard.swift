import SwiftUI
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
                    .font(AppTheme.Typography.amount)
                    .foregroundStyle(isExpense ? AppTheme.Colors.error : AppTheme.Colors.success)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}
