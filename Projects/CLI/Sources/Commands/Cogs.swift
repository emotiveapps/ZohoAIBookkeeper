import ArgumentParser
import Foundation
import ZohoBooksClient
import BookkeeperCore


struct Cogs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Compute periodic COGS for a year: beginning inventory + purchases − ending inventory"
    )

    @OptionGroup var options: CommonOptions

    @Option(name: .long, help: "Tax year")
    var year: Int?

    @Option(name: .long, help: "Inventory value at the start of the year (dollars)")
    var beginningInventory: Double = 0

    @Option(name: .long, help: "Inventory value at the end of the year (dollars, from your year-end count)")
    var endingInventory: Double

    func run() async throws {
        let config = try ConfigLoader.load()
        let client = try await createZohoClient(config: config, verbose: options.verbose)
        let taxYear = year ?? Calendar.current.component(.year, from: Date())

        print("Fetching \(taxYear) inventory purchases...")
        let expenses = try await client.fetchExpenses(
            dateStart: "\(taxYear)-01-01",
            dateEnd: "\(taxYear)-12-31"
        )
        let chartAccounts = try await client.fetchAccounts()
        let inventoryNames = TaxReadinessAuditor.inventoryAccountNames(in: chartAccounts)
        let (_, inventory) = TaxReadinessAuditor.summarize(
            expenses: expenses,
            inventoryAccountNames: inventoryNames
        )

        let money = TaxReadinessReportFormatter.money
        let purchases = inventory?.purchasesTotal ?? 0
        let cogs = beginningInventory + purchases - endingInventory

        print("\n\(Terminal.bold)FY\(taxYear) periodic COGS\(Terminal.reset)")
        print("  Beginning inventory:  \(money(beginningInventory))")
        print("  + Purchases:          \(money(purchases))")
        if let inventory {
            for account in inventory.byAccount {
                print("      \(Terminal.dim)\(account.name): \(money(account.total)) (\(account.count))\(Terminal.reset)")
            }
        } else {
            print("      \(Terminal.dim)(no purchases found in inventory/COGS accounts)\(Terminal.reset)")
        }
        print("  − Ending inventory:   \(money(endingInventory))")
        print("  \(Terminal.bold)= COGS:               \(money(cogs))\(Terminal.reset)")
        print("\n\(Terminal.dim)Give this to your accountant (Schedule C Part III). Confirm §471(c) treatment with your CPA.\(Terminal.reset)")
    }
}

