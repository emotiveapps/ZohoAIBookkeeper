import SwiftUI
import ZohoBooksClient
import BookkeeperCore

struct AccountRow: View {
    let account: ZBBankAccount
    let pendingCount: Int?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.accountName)
                HStack(spacing: 6) {
                    if let bankName = account.bankName, !bankName.isEmpty {
                        Text(bankName)
                    }
                    if account.accountType == "credit_card" {
                        Text("Credit card")
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if let pendingCount, pendingCount > 0 {
                Text("\(pendingCount)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(AppTheme.Colors.warning, in: Capsule())
            } else if pendingCount == 0 {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppTheme.Colors.success)
            }
        }
        .padding(.vertical, 2)
    }
}
