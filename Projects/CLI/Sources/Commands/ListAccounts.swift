import ArgumentParser
import Foundation
import ZohoBooksClient
import BookkeeperCore


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

