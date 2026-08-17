import ArgumentParser
import Foundation
import ZohoBooksClient
import BookkeeperCore

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
        let pipeline = SuggestionPipeline(claudeService: claudeService)

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

        // defer can't await, so it only restores the terminal (idempotent); the
        // cache is saved explicitly on every exit path, including thrown errors.
        defer { terminal.disableRawMode() }

        var processedCount = 0
        var skippedCount = 0
        var quitEarly = false

        do {
        reviewLoop: for (index, transaction) in unprocessedTransactions.enumerated() {
            // Show progress while fetching the AI suggestion + history refinement
            let aiSpinner = TerminalSpinner(
                terminal: terminal,
                message: "[\(index + 1)/\(unprocessedTransactions.count)] Getting suggestion for \(transaction.displayDescription.prefix(30))..."
            )
            aiSpinner.start()

            let historyResult = try await pipeline.suggestion(
                for: transaction,
                client: client,
                bankAccounts: bankAccounts,
                existingVendors: vendorNames,
                accountType: accountType
            )
            aiSpinner.stop(message: "Ready")

            let categorizedTx = CategorizedTransaction(
                transaction: transaction,
                suggestion: historyResult.suggestion
            )

            // Show editor
            let tx = transaction
            let txnGroup = tx.isDebit ? "money_out" : "money_in"
            let zohoURL = "https://books.zoho.com/app/\(config.zoho.organizationId)"
                + "#/banking/transactions/details?account_id=\(targetAccountId)"
                + "&bankaccount_id=\(targetAccountId)&transaction_id=\(tx.transactionId)"
                + "&filter_by=Status.Uncategorized&txn_group=\(txnGroup)&txn_status=uncategorized"
            let editor = TransactionEditor(
                terminal: terminal,
                transaction: categorizedTx,
                categories: categoryList,
                categoryConfigs: config.categoryMapping?.categories ?? [],
                vendors: vendorNames,
                bankAccounts: bankAccounts,
                accountType: accountType,
                debugLines: historyResult.debugLines,
                zohoURL: zohoURL
            )

            let result = editor.run()

            switch result {
            case .save(let editedTx):
                // A draft saved as "Skip" is just a skip; "Refund" can't be written
                // to Zoho, so surface that instead of silently marking it processed.
                if editedTx.selectedType == .skip {
                    skippedCount += 1
                    await cacheService.markSkipped(transaction.transactionId)
                } else if dryRun {
                    // Dry run: report, but leave the cache untouched so a real run
                    // still sees this transaction.
                    processedCount += 1
                } else {
                    let spinner = TerminalSpinner(terminal: terminal, message: "Saving...")
                    spinner.start()
                    do {
                        let categorizer = TransactionCategorizer(client: client)
                        let vendorUsed = try await categorizer.categorize(editedTx)
                        if let vendorUsed {
                            await cacheService.addVendor(vendorUsed)
                        }
                        spinner.stop(message: "Saved!")
                        processedCount += 1
                        await cacheService.markProcessed(transaction.transactionId)
                    } catch {
                        spinner.stop(message: "Error: \(error.localizedDescription)")
                        terminal.printAt(row: 3, col: 3, text: "\(Terminal.dim)Press any key to continue...\(Terminal.reset)")
                        _ = terminal.readKey()
                        skippedCount += 1
                    }
                }

            case .skip:
                skippedCount += 1
                await cacheService.markSkipped(transaction.transactionId)

            case .quit:
                quitEarly = true
                break reviewLoop
            }

        }
        } catch {
            terminal.disableRawMode()
            try? await cacheService.save()
            throw error
        }

        terminal.disableRawMode()
        print(quitEarly ? "\n\nQuitting..." : "\n\nComplete!")
        print("Processed: \(processedCount), Skipped: \(skippedCount)")
        try await cacheService.save()
    }
}
