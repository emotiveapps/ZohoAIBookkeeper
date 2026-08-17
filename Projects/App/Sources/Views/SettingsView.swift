import SwiftUI
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

    var body: some View {
        NavigationStack {
            Form {
                statusSection

                Section {
                    NavigationLink {
                        CredentialsEditorView(workspace: workspace, onSaved: { dismiss() })
                    } label: {
                        Label("Credentials", systemImage: "key")
                    }
                } footer: {
                    Text("Zoho and Anthropic API keys. These rarely change — they're tucked away here so they can't be edited by accident.")
                }

                receiptSyncSection
                maintenanceSection
            }
            .navigationTitle("Settings")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
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
                    .foregroundStyle(.secondary)
            }
            if let error = workspace.lastError {
                Label(error, systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
    }

    private var receiptSyncSection: some View {
        Section {
            switch workspace.receiptSyncStatus {
            case .running:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Syncing receipts…")
                        .foregroundStyle(.secondary)
                }
            case .finished(let line):
                syncResultRow(line, failed: false)
            case .failed(let line):
                syncResultRow(line, failed: true)
            case .idle:
                LabeledContent("Last synced") {
                    Text(lastSyncedDescription)
                        .foregroundStyle(.secondary)
                }
                if let result = workspace.lastReceiptSyncResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            Text("Processes files shared to the app and retries pending receipts against Zoho. Email and OneDrive inboxes sync via the Mac CLI. You can close Settings while a sync runs and check back here.")
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
            .foregroundStyle(failed ? .orange : .green)
            Text(line)
                .font(.caption)
                .foregroundStyle(.secondary)
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

/// Credential editing lives one level deep so the keys — which in practice
/// never change — can't be clobbered from the main Settings screen.
struct CredentialsEditorView: View {
    @Environment(AppModel.self) private var model
    let workspace: Workspace
    /// Called after a successful save & reconnect (closes the Settings sheet —
    /// the sheet's workspace reference is stale once the app reconnects).
    let onSaved: () -> Void

    @State private var form = CredentialsFormModel()
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        Form {
            CredentialsFormSections(form: $form)

            if let saveError {
                Section {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }

            Section {
                Button {
                    Task { await saveAndReconnect() }
                } label: {
                    HStack {
                        Spacer()
                        if isSaving { ProgressView().padding(.trailing, 6) }
                        Text("Save & Reconnect").fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(isSaving || !form.isValid)
            }
        }
        .navigationTitle("Credentials")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            form.apply(workspace.configuration)
        }
    }

    private func saveAndReconnect() async {
        isSaving = true
        saveError = nil
        saveError = await model.submitCredentials(form.configuration)
        isSaving = false
        if saveError == nil {
            onSaved()
        }
    }
}
