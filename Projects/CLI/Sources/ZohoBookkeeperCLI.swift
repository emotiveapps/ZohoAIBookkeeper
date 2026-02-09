import ArgumentParser
import Foundation
import ZohoBooksClient
import BookkeeperCore

@main
struct ZohoBookkeeperCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "zoho-bookkeeper",
        abstract: "AI-powered bookkeeping assistant for categorizing Zoho Books bank transactions",
        version: "1.0.0",
        subcommands: [Clean.self, ListAccounts.self],
        defaultSubcommand: Clean.self
    )
}

// MARK: - Common Options

struct CommonOptions: ParsableArguments {
    @Flag(name: .long, help: "Enable verbose output")
    var verbose: Bool = false
}

// MARK: - List Accounts Command

struct ListAccounts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-accounts",
        abstract: "List all bank accounts"
    )

    @OptionGroup var options: CommonOptions

    func run() async throws {
        let config = try ConfigLoader.load()
        let client = try await createZohoClient(config: config, verbose: options.verbose)

        print("Fetching bank accounts...")
        let accounts = try await client.fetchBankAccounts()

        print("\nBank Accounts:")
        print(String(repeating: "-", count: 60))
        for account in accounts {
            let balance = account.balance.map { String(format: "$%.2f", $0) } ?? "N/A"
            print("\(account.accountId): \(account.accountName) (\(balance))")
        }
        print(String(repeating: "-", count: 60))
        print("Total: \(accounts.count) accounts")
    }
}

// MARK: - Clean Command

struct Clean: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Interactively clean up uncategorized transactions"
    )

    @OptionGroup var options: CommonOptions

    @Option(name: .long, help: "Bank account ID to process")
    var account: String?

    @Option(name: .long, help: "Year to filter transactions (e.g., 2024)")
    var year: Int?

    @Flag(name: .long, help: "Dry run - don't actually categorize")
    var dryRun: Bool = false

    func run() async throws {
        let config = try ConfigLoader.load()
        let client = try await createZohoClient(config: config, verbose: options.verbose)

        // Get categories from config or fetch from Zoho
        let categories = config.categoryMapping?.allCategoryNames ?? []
        let categoryList = categories.isEmpty ? try await fetchExpenseCategories(client: client) : categories

        // Initialize services
        let claudeService = ClaudeService(
            apiKey: config.anthropic.apiKey,
            categories: categoryList,
            verbose: options.verbose
        )

        let cacheService = try CacheService()
        let historyMatcher = HistoryMatcher()

        // Get bank accounts
        print("Fetching bank accounts...")
        let bankAccounts = try await client.fetchBankAccounts()

        // Get target account
        let targetAccountId: String
        if let accountId = account {
            targetAccountId = accountId
        } else {
            // Prompt user to select account
            print("\nAvailable bank accounts:")
            for (index, acct) in bankAccounts.enumerated() {
                print("  \(index + 1). \(acct.accountName) (\(acct.accountId))")
            }
            print("\nEnter account number (1-\(bankAccounts.count)): ", terminator: "")
            guard let input = readLine(), let selection = Int(input),
                  selection >= 1 && selection <= bankAccounts.count else {
                print("Invalid selection")
                return
            }
            targetAccountId = bankAccounts[selection - 1].accountId
        }

        let targetAccount = bankAccounts.first { $0.accountId == targetAccountId }
        let accountType = targetAccount?.accountType ?? "bank"

        // Get vendors for suggestion matching
        print("Fetching vendors...")
        let vendors = try await client.fetchContacts(contactType: "vendor")
        let vendorNames = vendors.compactMap { $0.contactName }

        // Fetch uncategorized transactions
        print("Fetching uncategorized transactions...")
        let transactions = try await client.fetchUncategorizedTransactions(
            accountId: targetAccountId,
            year: year
        )

        if transactions.isEmpty {
            print("No uncategorized transactions found!")
            return
        }

        print("Found \(transactions.count) uncategorized transactions")

        // Filter to unprocessed transactions
        var unprocessedTransactions: [ZBBankTransaction] = []
        for tx in transactions {
            let isProcessed = await cacheService.isProcessed(tx.transactionId)
            let isSkipped = await cacheService.isSkipped(tx.transactionId)
            if !isProcessed && !isSkipped {
                unprocessedTransactions.append(tx)
            }
        }

        if unprocessedTransactions.isEmpty {
            print("All transactions have been processed!")
            return
        }

        print("Processing \(unprocessedTransactions.count) unprocessed transactions...")

        // Initialize terminal and process transactions
        let terminal = Terminal()
        terminal.enableRawMode()

        defer {
            terminal.disableRawMode()
            Task {
                try? await cacheService.save()
            }
        }

        var processedCount = 0
        var skippedCount = 0

        for (index, transaction) in unprocessedTransactions.enumerated() {
            // Show progress while fetching AI suggestion
            let aiSpinner = TerminalSpinner(
                terminal: terminal,
                message: "[\(index + 1)/\(unprocessedTransactions.count)] Getting AI suggestion for \(transaction.displayDescription.prefix(30))..."
            )
            aiSpinner.start()

            let suggestion = try await claudeService.suggestCategorization(
                transaction: transaction,
                bankAccounts: bankAccounts,
                existingVendors: vendorNames,
                accountType: accountType
            )
            aiSpinner.stop(message: "[\(index + 1)/\(unprocessedTransactions.count)] Checking history...", pause: false)

            let historySpinner = TerminalSpinner(terminal: terminal, message: "[\(index + 1)/\(unprocessedTransactions.count)] Checking vendor history...")
            historySpinner.start()
            let historyResult = try await historyMatcher.refine(
                suggestion: suggestion,
                transaction: transaction,
                client: client,
                bankAccountId: targetAccountId
            )
            historySpinner.stop(message: "Ready", pause: false)

            let categorizedTx = CategorizedTransaction(
                transaction: transaction,
                suggestion: historyResult.suggestion
            )

            // Show editor
            let tx = transaction
            let txnGroup = tx.isDebit ? "money_out" : "money_in"
            let zohoURL = "https://books.zoho.com/app/\(config.zoho.organizationId)#/banking/transactions/details?account_id=\(targetAccountId)&bankaccount_id=\(targetAccountId)&transaction_id=\(tx.transactionId)&filter_by=Status.Uncategorized&txn_group=\(txnGroup)&txn_status=uncategorized"
            let editor = TransactionEditor(
                terminal: terminal,
                transaction: categorizedTx,
                categories: categoryList,
                vendors: vendorNames,
                bankAccounts: bankAccounts,
                accountType: accountType,
                debugLines: historyResult.debugLines,
                zohoURL: zohoURL
            )

            let result = editor.run()

            switch result {
            case .save(let editedTx):
                if !dryRun {
                    let spinner = TerminalSpinner(terminal: terminal, message: "Saving...")
                    spinner.start()
                    do {
                        try await categorizeTransaction(
                            client: client,
                            transaction: editedTx,
                            cacheService: cacheService,
                            verbose: options.verbose
                        )
                        spinner.stop(message: "Saved!")
                        processedCount += 1
                        await cacheService.markProcessed(transaction.transactionId)
                    } catch {
                        spinner.stop(message: "Error: \(error.localizedDescription)")
                        terminal.printAt(row: 3, col: 3, text: "\(Terminal.dim)Press any key to continue...\(Terminal.reset)")
                        _ = terminal.readKey()
                        skippedCount += 1
                    }
                } else {
                    processedCount += 1
                    await cacheService.markProcessed(transaction.transactionId)
                }

            case .skip:
                skippedCount += 1
                await cacheService.markSkipped(transaction.transactionId)

            case .quit:
                terminal.disableRawMode()
                print("\n\nQuitting...")
                print("Processed: \(processedCount), Skipped: \(skippedCount)")
                try await cacheService.save()
                return
            }

        }

        terminal.disableRawMode()
        print("\n\nComplete!")
        print("Processed: \(processedCount), Skipped: \(skippedCount)")
        try await cacheService.save()
    }
}

// MARK: - Helper Functions

func createZohoClient(config: FullConfiguration, verbose: Bool) async throws -> ZohoBooksClient<ZohoOAuth> {
    let zohoConfig = ZohoConfig(
        clientId: config.zoho.clientId,
        clientSecret: config.zoho.clientSecret,
        accessToken: config.zoho.accessToken,
        refreshToken: config.zoho.refreshToken,
        organizationId: config.zoho.organizationId,
        region: ZohoRegion(rawValue: config.zoho.region) ?? .com
    )

    let client = ZohoBooksClient(config: zohoConfig, verbose: verbose)
    await client.configure()
    return client
}

func fetchExpenseCategories(client: ZohoBooksClient<ZohoOAuth>) async throws -> [String] {
    let accounts = try await client.fetchAccounts()
    return accounts
        .filter { ($0.accountType ?? "").lowercased() == "expense" }
        .compactMap { $0.accountName }
        .sorted()
}

func categorizeTransaction(
    client: ZohoBooksClient<ZohoOAuth>,
    transaction: CategorizedTransaction,
    cacheService: CacheService,
    verbose: Bool
) async throws {
    let tx = transaction.transaction

    switch transaction.selectedType {
    case .expense:
        // Get or create vendor if specified
        var vendorId: String?
        if !transaction.vendorName.isEmpty {
            let vendor = try await client.getOrCreateVendor(name: transaction.vendorName)
            vendorId = vendor.contactId
            await cacheService.addVendor(transaction.vendorName)
        }

        // Find category account
        let categoryAccount = try await client.searchAccountByName(transaction.category)

        let request = ZBCategorizeExpenseRequest(
            accountId: categoryAccount?.accountId ?? "",
            vendorId: vendorId,
            paidThroughAccountId: tx.accountId,
            description: transaction.description,
            date: tx.date,
            amount: tx.amount
        )

        if verbose {
            print("Categorizing as expense: \(transaction.category), vendor: \(transaction.vendorName)")
        }

        try await client.categorizeAsExpense(transactionId: tx.transactionId, request: request)

    case .transfer:
        let request = ZBCategorizeTransferRequest(
            toAccountId: transaction.transferToAccountId,
            amount: tx.amount,
            description: transaction.description
        )

        if verbose {
            print("Categorizing as transfer")
        }

        try await client.categorizeAsTransfer(transactionId: tx.transactionId, request: request)

    case .ownerContribution:
        // Find owner's equity account
        let equityAccount = try await client.searchAccountByName("Owner's Equity")

        let request = ZBCategorizeOwnerContributionRequest(
            accountId: equityAccount?.accountId ?? "",
            description: transaction.description
        )

        if verbose {
            print("Categorizing as owner contribution")
        }

        try await client.categorizeAsOwnerContribution(transactionId: tx.transactionId, request: request)

    case .sale:
        // Find sales/income account
        let salesAccount = try await client.searchAccountByName("Sales")

        let request = ZBCategorizeSaleRequest(
            accountId: salesAccount?.accountId ?? "",
            description: transaction.description
        )

        if verbose {
            print("Categorizing as sale")
        }

        try await client.categorizeAsSale(transactionId: tx.transactionId, request: request)

    case .refund, .skip:
        // Skip - don't categorize
        if verbose {
            print("Skipping transaction")
        }
    }
}

