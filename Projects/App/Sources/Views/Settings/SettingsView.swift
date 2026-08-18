import SwiftUI
import DesignSystem
import BookkeeperCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let workspace: Workspace

    @State private var showingSignOutConfirmation = false
    @State private var showingResetConfirmation = false
    @State private var didResetCache = false
    @State private var showingSyncQuotaWarning = false
    @State private var didSendWatchCount = false
    @State private var showingMicrosoftSignIn = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                statusSection

                Section {
                    connectionRow("Zoho Books", health: workspace.zohoHealth)
                    connectionRow("Claude (Anthropic)", health: workspace.anthropicHealth)
                    connectionRow(
                        "Receipt Mailbox",
                        health: workspace.mailboxHealth,
                        detail: workspace.configuration.receipts?.mailboxes.first?.address
                    )
                    connectionRow(
                        "Receipt Folder (OneDrive)",
                        health: workspace.oneDriveHealth,
                        detail: workspace.configuration.receipts?.onedrive?.folderPath
                    )
                    if let graph = workspace.graphMail,
                       case .unavailable = workspace.mailboxHealth {
                        Button("Sign In to Microsoft…") {
                            showingMicrosoftSignIn = true
                        }
                        .sheet(isPresented: $showingMicrosoftSignIn, onDismiss: {
                            workspace.refreshMicrosoftHealth()
                        }) {
                            MicrosoftSignInSheet(graph: graph)
                        }
                    }
                    NavigationLink {
                        CredentialsEditorView(workspace: workspace, onSaved: { dismiss() })
                    } label: {
                        Label("Credentials", systemImage: "key")
                    }
                } footer: {
                    Text("Zoho and Anthropic API keys.")
                }
                .task {
                    workspace.refreshMicrosoftHealth()
                    await workspace.checkAnthropicHealth()
                }

                receiptSyncSection
                maintenanceSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Gradients.background)
            .navigationTitle("Settings")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    workspace.refreshMicrosoftHealth()
                }
            }
        }
    }

    private var statusSection: some View {
        Section("Connection") {
            LabeledContent("Accounts", value: "\(workspace.bankAccounts.count)")
            LabeledContent("Categories", value: "\(workspace.categories.count)")
            LabeledContent("Vendors", value: "\(workspace.vendors.count)")
            LabeledContent("Category source") {
                Text(workspace.categoryConfigs.isEmpty ? "Zoho chart of accounts" : "Imported hierarchy")
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            if let error = workspace.lastError {
                Label(error, systemImage: "wifi.exclamationmark")
                    .foregroundStyle(Theme.Colors.error)
                    .font(.callout)
            }
        }
    }

    private func connectionRow(
        _ title: String,
        health: Workspace.ServiceHealth,
        detail: String? = nil
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if case .unavailable(let reason) = health {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(2)
                } else if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            Spacer()
            switch health {
            case .checking:
                ProgressView().controlSize(.small)
            case .ok:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.Colors.success)
            case .unavailable:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.Colors.error)
            case .notConfigured:
                Image(systemName: "minus.circle")
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var receiptSyncSection: some View {
        Section {
            switch workspace.receiptSyncStatus {
            case .running:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Syncing receipts…")
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            case .finished(let line):
                syncResultRow(line, failed: false)
            case .failed(let line):
                syncResultRow(line, failed: true)
            case .idle:
                LabeledContent("Last synced") {
                    Text(lastSyncedDescription)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                if let result = workspace.lastReceiptSyncResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }

            Button("Sync Receipts Now") {
                if let last = workspace.lastReceiptSyncAt,
                   Date().timeIntervalSince(last) < 24 * 3600 {
                    showingSyncQuotaWarning = true
                } else {
                    Task { await workspace.syncReceiptsNow() }
                }
            }
            .disabled(workspace.isSyncingReceipts)
        } header: {
            Text("Receipts")
        } footer: {
            Text(
                "Processes files shared to the app, sweeps the receipt mailbox and OneDrive folder "
                    + "when signed in to Microsoft on this device, and retries pending receipts "
                    + "against Zoho. You can close Settings while a sync runs and check back here."
            )
        }
        .confirmationDialog(
            "Sync again already?",
            isPresented: $showingSyncQuotaWarning,
            titleVisibility: .visible
        ) {
            Button("Sync Anyway") {
                Task { await workspace.syncReceiptsNow() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You synced less than 24 hours ago. Retrying every pending receipt makes heavy use of the Zoho API quota.")
        }
    }

    private func syncResultRow(_ line: String, failed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                failed ? "Finished with errors" : "Finished",
                systemImage: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
            )
            .foregroundStyle(failed ? Theme.Colors.warning : Theme.Colors.success)
            Text(line)
                .font(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
            Text("Last synced \(lastSyncedDescription)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var lastSyncedDescription: String {
        guard let last = workspace.lastReceiptSyncAt else { return "Never" }
        return last.formatted(.relative(presentation: .named))
    }

    private var maintenanceSection: some View {
        Section {
            Button(didSendWatchCount ? "Watch count sent" : "Update watch count") {
                WatchSync.shared.send(totalPending: workspace.totalPendingCount)
                didSendWatchCount = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    didSendWatchCount = false
                }
            }
            .disabled(didSendWatchCount)

            Button(didResetCache ? "Local progress cleared" : "Clear local progress") {
                showingResetConfirmation = true
            }
            .disabled(didResetCache)

            Button("Sign Out", role: .destructive) {
                showingSignOutConfirmation = true
            }
        } header: {
            Text("Maintenance")
        } footer: {
            Text("Clearing local progress forgets which transactions were processed or skipped on this device; they'll show up for review again. Signing out removes credentials from the Keychain.")
        }
        .confirmationDialog(
            "Clear local progress?",
            isPresented: $showingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                Task { await clearCache() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Sign out?",
            isPresented: $showingSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                dismiss()
                model.signOut()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Credentials will be removed from this device.")
        }
    }

    private func clearCache() async {
        guard let cache = workspace.cache else { return }
        await cache.clear()
        try? await cache.save()
        didResetCache = true
        await workspace.refreshCacheStats()
        await workspace.refreshPendingCounts()
    }
}
