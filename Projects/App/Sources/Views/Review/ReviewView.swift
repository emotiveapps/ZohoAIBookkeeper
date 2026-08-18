import SwiftUI
import DesignSystem
import ZohoBooksClient
import BookkeeperCore

/// The triage loop for one account: one transaction at a time, AI suggestion
/// pre-applied, Save/Skip at the bottom, auto-advance with prefetch.
struct ReviewView: View {
    let workspace: Workspace
    let account: ZBBankAccount

    @State private var session: ReviewSession?
    @State private var activeSheet: EditorSheet?
    @State private var showQueueList = false

    enum EditorSheet: Identifiable {
        case category
        case vendor

        var id: Self { self }
    }

    var body: some View {
        Group {
            if let session {
                content(session)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(account.accountName)
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            let session = self.session ?? {
                let newSession = ReviewSession(workspace: workspace, account: account)
                self.session = newSession
                return newSession
            }()
            // The transition into a collapsed NavigationSplitView detail can cancel
            // this task and re-run it; a session still in .loading needs a (re)start.
            if session.state == .loading {
                await session.start()
            }
        }
    }

    @ViewBuilder
    private func content(_ session: ReviewSession) -> some View {
        switch session.state {
        case .loading:
            ProgressView("Loading transactions…")

        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't load transactions", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") {
                    Task { await session.start() }
                }
                .buttonStyle(.borderedProminent)
            }

        case .finished:
            ContentUnavailableView {
                Label("All caught up", systemImage: "checkmark.seal.fill")
            } description: {
                if session.savedCount + session.skippedCount + session.deletedCount > 0 {
                    Text(sessionSummary(session))
                } else {
                    Text("No uncategorized transactions in this account.")
                }
            }

        case .reviewing:
            reviewer(session)
        }
    }

    private func sessionSummary(_ session: ReviewSession) -> String {
        var parts: [String] = []
        if session.savedCount > 0 { parts.append("saved \(session.savedCount)") }
        if session.deletedCount > 0 { parts.append("deleted \(session.deletedCount)") }
        if session.skippedCount > 0 { parts.append("skipped \(session.skippedCount)") }
        let joined = parts.joined(separator: ", ")
        return joined.prefix(1).uppercased() + joined.dropFirst() + " this session."
    }

    private func reviewer(_ session: ReviewSession) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                content(for: session)
            }
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
            .padding()
        }
        .background(Theme.Gradients.background)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            actionBar(session)
        }
        .animation(.default, value: session.isPreparing)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showQueueList = true
                } label: {
                    Label("Queue", systemImage: "list.bullet")
                }
            }
        }
        .sheet(isPresented: $showQueueList) {
            QueueListSheet(queue: session.queue, position: session.position) { index in
                Task { await session.jump(to: index) }
            }
        }
    }

    @ViewBuilder
    private func content(for session: ReviewSession) -> some View {
        if let draft = session.draft {
            TransactionHeaderCard(
                transaction: draft.transaction,
                accountType: account.accountType
            )

            suggestionCard(session, draft: draft)
            decisionCard(session, draft: draft)

            if let url = session.zohoURL {
                Link(destination: url) {
                    Label("Open in Zoho Books", systemImage: "safari")
                        .font(.callout)
                }
            }
        } else {
            preparingCard
        }
    }

    private var preparingCard: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Getting AI suggestion…")
                .font(.callout)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func suggestionCard(_ session: ReviewSession, draft: CategorizedTransaction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("AI suggestion", systemImage: "sparkles")
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Colors.accent)
                Spacer()
                ConfidenceBadge(confidence: draft.suggestion.confidence)
                Button {
                    Task { await session.regenerateSuggestion() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(session.isPreparing)
                .accessibilityLabel("Regenerate suggestion")
            }

            if !draft.suggestion.reasoning.isEmpty {
                Text(draft.suggestion.reasoning)
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }

            ForEach(session.historyNotes, id: \.self) { note in
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func decisionCard(_ session: ReviewSession, draft: CategorizedTransaction) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Type")
                Spacer()
                Picker("Type", selection: binding(session, draft, \.selectedType)) {
                    ForEach(session.availableTypes, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            .decisionRow()

            if draft.selectedType == .expense {
                Divider()
                Button {
                    activeSheet = .category
                } label: {
                    LabeledContent("Category") {
                        HStack(spacing: 4) {
                            Text(draft.category.isEmpty ? "Choose…" : draft.category)
                                .foregroundStyle(draft.category.isEmpty ? .secondary : .primary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .decisionRow()

                Divider()
                Button {
                    activeSheet = .vendor
                } label: {
                    LabeledContent("Vendor") {
                        HStack(spacing: 4) {
                            Text(draft.vendorName.isEmpty ? "None" : draft.vendorName)
                                .foregroundStyle(draft.vendorName.isEmpty ? .secondary : .primary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .decisionRow()
            }

            if draft.selectedType == .transfer {
                Divider()
                Picker(
                    draft.transaction.isDebit ? "To account" : "From account",
                    selection: binding(session, draft, \.transferToAccountId)
                ) {
                    Text("Choose…").tag(nil as String?)
                    ForEach(transferTargets, id: \.accountId) { target in
                        Text(target.accountName).tag(target.accountId as String?)
                    }
                }
                .pickerStyle(.menu)
                .decisionRow()
            }

            Divider()
            TextField("Description", text: binding(session, draft, \.description), axis: .vertical)
                .lineLimit(1 ... 3)
                .decisionRow()

            if let error = session.errorMessage {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Theme.Colors.error)
                    .decisionRow()
            }
        }
        .background(Theme.Colors.card, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .sheet(item: $activeSheet) { sheet in
            Group {
                switch sheet {
                case .category:
                    CategoryPickerSheet(
                        categoryConfigs: workspace.categoryConfigs,
                        flatCategories: workspace.categories,
                        selection: draft.category
                    ) { selected in
                        session.draft?.category = selected
                    }
                case .vendor:
                    VendorPickerSheet(
                        vendors: workspace.vendors,
                        selection: draft.vendorName
                    ) { selected in
                        session.draft?.vendorName = selected
                    }
                }
            }
            // Medium detent first: the picker floats over the visible review
            // screen (the system's glassy partial-sheet treatment); drag to
            // large for the full list, where the sheet turns opaque.
            .presentationDetents([.medium, .large])
        }
    }

    private func actionBar(_ session: ReviewSession) -> some View {
        HStack(spacing: 12) {
            Button {
                Task { await session.goBack() }
            } label: {
                Image(systemName: "chevron.backward")
            }
            .buttonStyle(.glass)
            .disabled(!session.canGoBack || session.isSaving)

            Text("\(min(session.position + 1, session.totalCount)) of \(session.totalCount)")
                .font(Theme.Typography.counter)
                .foregroundStyle(Theme.Colors.textSecondary)
                .frame(minWidth: 48)

            Button {
                Task { await session.goForward() }
            } label: {
                Image(systemName: "chevron.forward")
            }
            .buttonStyle(.glass)
            .disabled(!session.canGoForward || session.isSaving)

            Button(role: .destructive) {
                Task { await session.delete() }
            } label: {
                Text("Delete")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .tint(Theme.Colors.error)
            .disabled(session.draft == nil || session.isSaving || session.isPreparing)

            Button {
                Task { await session.save() }
            } label: {
                HStack {
                    if session.isSaving {
                        ProgressView().controlSize(.small)
                    }
                    Text("Save")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .disabled(session.draft == nil || session.isSaving || session.isPreparing)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        // Liquid Glass controls float over the scrolling content — no opaque
        // bar, so nothing to mismatch against the panels on iPad.
    }

    private var transferTargets: [ZBBankAccount] {
        workspace.bankAccounts.filter { $0.accountId != account.accountId }
    }

    /// Two-way binding into the optional draft held by the session. UIKit can
    /// read a binding after Save/Skip cleared the draft (e.g. a menu picker
    /// mid-dismiss), so reads fall back to the snapshot the row was built from;
    /// writes to a gone draft are no-ops.
    private func binding<Value>(
        _ session: ReviewSession,
        _ snapshot: CategorizedTransaction,
        _ keyPath: WritableKeyPath<CategorizedTransaction, Value>
    ) -> Binding<Value> where Value: Sendable {
        Binding {
            (session.draft ?? snapshot)[keyPath: keyPath]
        } set: { newValue in
            session.draft?[keyPath: keyPath] = newValue
        }
    }
}
