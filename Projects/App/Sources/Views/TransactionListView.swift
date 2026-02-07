import SwiftUI
import BookkeeperCore
import ZohoBooksClient

struct TransactionListView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel: TransactionListViewModel
    let account: ZBBankAccount

    init(account: ZBBankAccount) {
        self.account = account
        _viewModel = StateObject(wrappedValue: TransactionListViewModel(
            cacheService: try! CacheService()
        ))
    }

    var body: some View {
        List {
            ForEach(viewModel.transactions, id: \.transactionId) { transaction in
                NavigationLink {
                    TransactionEditorView(
                        transaction: transaction,
                        categories: appState.categories,
                        vendors: appState.vendors,
                        bankAccounts: appState.bankAccounts
                    )
                } label: {
                    transactionRow(transaction)
                }
            }
        }
        .navigationTitle(account.accountName)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if viewModel.isLoading {
                ProgressView("Loading...")
            } else if viewModel.transactions.isEmpty {
                ContentUnavailableView(
                    "No Pending Transactions",
                    systemImage: "checkmark.circle",
                    description: Text("All transactions have been categorized")
                )
            }
        }
        .refreshable {
            await loadTransactions()
        }
        .task {
            await loadTransactions()
        }
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") {
                viewModel.errorMessage = nil
            }
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
    }

    private func loadTransactions() async {
        guard let client = appState.zohoClient else { return }
        await viewModel.loadTransactions(
            client: client,
            accountId: account.accountId
        )
    }

    private func transactionRow(_ transaction: ZBBankTransaction) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.displayDescription)
                    .font(.body)
                    .lineLimit(1)

                Text(transaction.date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(transaction.displayAmount)
                .font(.body)
                .fontWeight(.medium)
                .foregroundStyle(transaction.isDebit ? .red : .green)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        TransactionListView(
            account: ZBBankAccount(
                accountId: "123",
                accountName: "Test Account",
                accountType: "bank",
                balance: 1000.0,
                bankName: "Test Bank",
                currencyCode: "USD"
            )
        )
    }
    .environmentObject(AppState())
}
