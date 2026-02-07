import SwiftUI
import BookkeeperCore
import ZohoBooksClient

struct TransactionEditorView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: TransactionEditorViewModel

    init(
        transaction: ZBBankTransaction,
        categories: [String],
        vendors: [String],
        bankAccounts: [ZBBankAccount]
    ) {
        _viewModel = StateObject(wrappedValue: TransactionEditorViewModel(
            transaction: transaction,
            categories: categories,
            vendors: vendors,
            bankAccounts: bankAccounts
        ))
    }

    var body: some View {
        Form {
            // Transaction Details Section
            Section("Transaction") {
                LabeledContent("Amount") {
                    Text(viewModel.categorizedTransaction.transaction.displayAmount)
                        .foregroundStyle(
                            viewModel.categorizedTransaction.transaction.isDebit ? .red : .green
                        )
                        .fontWeight(.semibold)
                }

                LabeledContent("Date") {
                    Text(viewModel.categorizedTransaction.transaction.date)
                }

                LabeledContent("Description") {
                    Text(viewModel.categorizedTransaction.transaction.displayDescription)
                        .lineLimit(2)
                }

                if let payee = viewModel.categorizedTransaction.transaction.payee {
                    LabeledContent("Payee") {
                        Text(payee)
                    }
                }
            }

            // AI Suggestion Section
            Section {
                HStack {
                    Text("AI Confidence")
                    Spacer()
                    confidenceBadge
                }

                if !viewModel.categorizedTransaction.suggestion.reasoning.isEmpty {
                    Text(viewModel.categorizedTransaction.suggestion.reasoning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task {
                        await viewModel.requestAISuggestion()
                    }
                } label: {
                    HStack {
                        if viewModel.isLoadingSuggestion {
                            ProgressView()
                                .padding(.trailing, 4)
                        }
                        Text("Get AI Suggestion")
                    }
                }
                .disabled(viewModel.isLoadingSuggestion || appState.claudeService == nil)
            } header: {
                Text("AI Suggestion")
            }

            // Categorization Section
            Section("Categorization") {
                Picker("Type", selection: $viewModel.categorizedTransaction.selectedType) {
                    ForEach(viewModel.availableTransactionTypes, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }

                if viewModel.categorizedTransaction.selectedType == .expense {
                    Picker("Category", selection: $viewModel.categorizedTransaction.category) {
                        ForEach(viewModel.availableCategories, id: \.self) { category in
                            Text(category).tag(category)
                        }
                    }

                    TextField("Vendor", text: $viewModel.categorizedTransaction.vendorName)
                        .autocorrectionDisabled()
                }

                if viewModel.categorizedTransaction.selectedType == .transfer {
                    Picker("To Account", selection: $viewModel.categorizedTransaction.transferToAccountId) {
                        Text("Select...").tag(nil as String?)
                        ForEach(viewModel.bankAccounts, id: \.accountId) { account in
                            Text(account.accountName).tag(account.accountId as String?)
                        }
                    }
                }

                TextField("Description", text: $viewModel.categorizedTransaction.description)
            }

            // Actions Section
            Section {
                Button {
                    Task {
                        await saveTransaction()
                    }
                } label: {
                    HStack {
                        Spacer()
                        if viewModel.isSaving {
                            ProgressView()
                                .padding(.trailing, 8)
                        }
                        Text("Save")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(viewModel.isSaving)

                Button(role: .destructive) {
                    Task {
                        await skipTransaction()
                    }
                } label: {
                    HStack {
                        Spacer()
                        Text("Skip")
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("Edit Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") {
                viewModel.errorMessage = nil
            }
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
        .onAppear {
            // Set the Claude service if available
            if let claudeService = appState.claudeService {
                // Note: In a real app, we'd pass this through the initializer
            }
        }
    }

    private var confidenceBadge: some View {
        let confidence = viewModel.categorizedTransaction.suggestion.confidence
        let color: Color = confidence >= 80 ? .green : confidence >= 50 ? .orange : .red

        return Text("\(confidence)%")
            .font(.caption)
            .fontWeight(.bold)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func saveTransaction() async {
        guard let client = appState.zohoClient,
              let cache = appState.cacheService else { return }

        let success = await viewModel.save(client: client, cacheService: cache)
        if success {
            dismiss()
        }
    }

    private func skipTransaction() async {
        guard let cache = appState.cacheService else { return }
        await cache.markSkipped(viewModel.categorizedTransaction.transaction.transactionId)
        dismiss()
    }
}

#Preview {
    NavigationStack {
        TransactionEditorView(
            transaction: ZBBankTransaction(
                transactionId: "123",
                date: "2024-01-15",
                amount: 42.50,
                debitOrCredit: "debit",
                description: "AMAZON.COM*123456",
                referenceNumber: "REF123", payee: "Amazon",
                accountId: "acc123"
            ),
            categories: ["Office Supplies", "Software", "Travel"],
            vendors: ["Amazon", "Apple", "Google"],
            bankAccounts: []
        )
    }
    .environmentObject(AppState())
}
