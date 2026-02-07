import SwiftUI
import BookkeeperCore
import ZohoBooksClient

struct AccountListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationStack {
            List(appState.bankAccounts, id: \.accountId) { account in
                NavigationLink {
                    TransactionListView(account: account)
                } label: {
                    accountRow(account)
                }
            }
            .navigationTitle("Bank Accounts")
            .overlay {
                if appState.bankAccounts.isEmpty {
                    ContentUnavailableView(
                        "No Accounts",
                        systemImage: "building.columns",
                        description: Text("Connect to Zoho Books to see your bank accounts")
                    )
                }
            }
            .refreshable {
                await appState.connect()
            }
        }
    }

    private func accountRow(_ account: ZBBankAccount) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(account.accountName)
                .font(.body)

            HStack {
                if let bankName = account.bankName {
                    Text(bankName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let balance = account.balance {
                    Text(String(format: "$%.2f", balance))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(balance >= 0 ? .green : .red)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    AccountListView()
        .environmentObject(AppState())
}
