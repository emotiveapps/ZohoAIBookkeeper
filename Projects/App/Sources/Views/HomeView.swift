import SwiftUI
import ZohoBooksClient
import BookkeeperCore

/// Accounts sidebar + review detail. Collapses to a stack on iPhone.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    let workspace: Workspace

    @State private var selectedAccountId: String?
    @State private var showingSettings = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(workspace: workspace)
        }
    }

    private var sidebar: some View {
        List(selection: $selectedAccountId) {
            if let error = workspace.lastError {
                Section {
                    Label(error, systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }

            Section("Accounts") {
                ForEach(workspace.bankAccounts, id: \.accountId) { account in
                    AccountRow(
                        account: account,
                        pendingCount: workspace.pendingCounts[account.accountId]
                    )
                    .tag(account.accountId)
                }
            }

            Section("This device") {
                HStack(spacing: 12) {
                    StatTile(title: "Done", value: workspace.processedCount, tint: .green)
                    StatTile(title: "Skipped", value: workspace.skippedCount, tint: .orange)
                    StatTile(title: "Vendors", value: workspace.vendors.count, tint: .blue)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Bookkeeper")
        .overlay {
            if workspace.bankAccounts.isEmpty && workspace.isRefreshing {
                ProgressView("Loading accounts…")
            } else if workspace.bankAccounts.isEmpty {
                ContentUnavailableView(
                    "No Accounts",
                    systemImage: "building.columns",
                    description: Text("Pull to refresh, or check your credentials in Settings.")
                )
            }
        }
        .refreshable {
            await workspace.refresh()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .task {
            // Bootstrap already refreshes; this covers re-entry after settings changes.
            if workspace.bankAccounts.isEmpty && !workspace.isRefreshing {
                await workspace.refresh()
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let account = workspace.bankAccounts.first(where: { $0.accountId == selectedAccountId }) {
            ReviewView(workspace: workspace, account: account)
                .id(account.accountId)
        } else {
            ContentUnavailableView(
                "Pick an account",
                systemImage: "tray.full",
                description: Text("Choose a bank account to start reviewing its uncategorized transactions.")
            )
        }
    }
}

private struct AccountRow: View {
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
                    .background(.orange, in: Capsule())
            } else if pendingCount == 0 {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
    }
}
