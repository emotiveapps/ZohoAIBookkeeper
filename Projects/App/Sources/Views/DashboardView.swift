import SwiftUI
import BookkeeperCore
import ZohoBooksClient

struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel: DashboardViewModel

    init() {
        // We'll set the real cache service in onAppear
        _viewModel = StateObject(wrappedValue: DashboardViewModel(
            cacheService: try! CacheService()
        ))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Summary Card
                    summaryCard

                    // Account Cards
                    accountsSection

                    // Cache Stats
                    cacheStatsSection
                }
                .padding()
            }
            .navigationTitle("Dashboard")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task {
                            if let client = appState.zohoClient {
                                await viewModel.loadDashboard(client: client)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .refreshable {
                if let client = appState.zohoClient {
                    await viewModel.loadDashboard(client: client)
                }
            }
            .task {
                if let client = appState.zohoClient {
                    await viewModel.loadDashboard(client: client)
                }
            }
        }
    }

    private var summaryCard: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Pending Transactions")
                    .font(.headline)
                Spacer()
            }

            HStack {
                Text("\(viewModel.totalPendingCount)")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(viewModel.totalPendingCount > 0 ? .orange : .green)

                Spacer()

                if viewModel.isLoading {
                    ProgressView()
                }
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 2)
    }

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Accounts")
                .font(.headline)
                .padding(.horizontal)

            ForEach(viewModel.bankAccounts, id: \.accountId) { account in
                accountRow(account)
            }
        }
    }

    private func accountRow(_ account: ZBBankAccount) -> some View {
        NavigationLink {
            TransactionListView(account: account)
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(account.accountName)
                        .font(.body)
                        .foregroundStyle(.primary)

                    if let balance = account.balance {
                        Text(String(format: "$%.2f", balance))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                let pendingCount = viewModel.pendingCounts[account.accountId] ?? 0
                if pendingCount > 0 {
                    Text("\(pendingCount)")
                        .font(.caption)
                        .fontWeight(.bold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.orange)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }

                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var cacheStatsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Statistics")
                .font(.headline)

            HStack(spacing: 20) {
                StatBox(title: "Processed", value: "0", color: .green)
                StatBox(title: "Skipped", value: "0", color: .orange)
                StatBox(title: "Vendors", value: "0", color: .blue)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 2)
    }
}

struct StatBox: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack {
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(color)

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    DashboardView()
        .environmentObject(AppState())
}
