import SwiftUI
import ZohoBooksClient
import BookkeeperCore

/// Accounts sidebar + review detail. Collapses to a stack on iPhone.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    let workspace: Workspace

    @State private var selectedAccountId: String?
    @State private var showingSettings = false
    @State private var showingReadiness = false
    @State private var showingReceipts = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(workspace: workspace)
        }
        .sheet(isPresented: $showingReadiness) {
            ReadinessView(workspace: workspace)
        }
        .sheet(isPresented: $showingReceipts) {
            ReceiptsView(workspace: workspace)
        }
    }

    private var sidebar: some View {
        List(selection: $selectedAccountId) {
            if let error = workspace.lastError {
                Section {
                    Label(error, systemImage: "wifi.exclamationmark")
                        .foregroundStyle(AppTheme.Colors.error)
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

            Section {
                Button {
                    showingReadiness = true
                } label: {
                    HStack {
                        Label {
                            Text("Tax readiness")
                        } icon: {
                            Image(systemName: "checkmark.seal")
                                .foregroundStyle(AppTheme.Colors.aspiration)
                        }
                        Spacer()
                        if workspace.totalPendingCount > 0 {
                            Text("\(workspace.totalPendingCount) to review")
                                .font(.caption)
                                .foregroundStyle(AppTheme.Colors.warning)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.primary)

                Button {
                    showingReceipts = true
                } label: {
                    HStack {
                        Label("Receipts", systemImage: "doc.text.viewfinder")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.primary)
            } header: {
                Text("Filing")
            } footer: {
                Text("Audit: uncategorized items, bank-feed gaps, totals. Receipts: archive, share-sheet capture, expense matching.")
            }

            Section("This device") {
                HStack(spacing: 12) {
                    StatTile(title: "Done", value: workspace.processedCount, tint: AppTheme.Colors.success)
                    StatTile(title: "Skipped", value: workspace.skippedCount, tint: AppTheme.Colors.warning)
                    StatTile(title: "Vendors", value: workspace.vendors.count, tint: AppTheme.Colors.accent)
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
