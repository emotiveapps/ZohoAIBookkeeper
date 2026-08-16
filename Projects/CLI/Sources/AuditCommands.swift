import ArgumentParser
import Foundation
import ZohoBooksClient
import BookkeeperCore

// MARK: - Audit

struct Audit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Tax-readiness report for a year: uncategorized counts, feed gaps, expense totals",
        discussion: "Exits non-zero when blockers exist, so it can gate a filing checklist."
    )

    @OptionGroup var options: CommonOptions

    @Option(name: .long, help: "Tax year to audit (default: current year)")
    var year: Int?

    @Flag(name: .long, help: "Also verify receipts are attached (one API call per expense ≥ threshold — slow)")
    var receipts: Bool = false

    @Option(name: .long, help: "Receipt-check amount threshold in dollars")
    var threshold: Double = 75

    @Flag(name: .long, help: "Write markdown + CSV to ~/.zoho-ai-bookkeeper/reports/<year>/")
    var export: Bool = false

    func run() async throws {
        let config = try ConfigLoader.load()
        let client = try await createZohoClient(config: config, verbose: options.verbose)
        let auditYear = year ?? Calendar.current.component(.year, from: Date())

        let auditor = TaxReadinessAuditor(client: client)
        let report = try await auditor.audit(
            year: auditYear,
            checkDocumentation: receipts,
            receiptThreshold: threshold,
            progress: { status in print("  \(status)") }
        )

        printReport(report)

        if export {
            let dir = try exportReport(report)
            print("\nExported to \(dir.path)")
        }

        if !report.blockers.isEmpty {
            throw ExitCode(2)
        }
    }

    private func printReport(_ report: TaxReadinessReport) {
        let money = TaxReadinessReportFormatter.money

        print("\n\(Terminal.bold)Tax readiness — FY\(report.year)\(Terminal.reset)")
        print(String(repeating: "─", count: 60))

        if report.blockers.isEmpty {
            print("\(Terminal.brightGreen)✓ No blockers found\(Terminal.reset)")
        } else {
            print("\(Terminal.brightRed)Blockers:\(Terminal.reset)")
            for blocker in report.blockers {
                print("  \(Terminal.brightRed)✗\(Terminal.reset) \(blocker)")
            }
        }

        print("\n\(Terminal.bold)Accounts\(Terminal.reset)")
        for account in report.accounts {
            let uncategorized = account.uncategorizedCount > 0
                ? "\(Terminal.brightYellow)\(account.uncategorizedCount) uncategorized\(Terminal.reset)"
                : "\(Terminal.dim)0 uncategorized\(Terminal.reset)"
            print("  \(account.accountName): \(account.transactionCount) tx, \(uncategorized)")
            for finding in account.gaps.findings {
                let color = finding.severity == .critical ? Terminal.brightRed : Terminal.brightYellow
                print("    \(color)⚠ \(finding.summary)\(Terminal.reset)")
            }
        }

        print("\n\(Terminal.bold)Expenses\(Terminal.reset): \(report.expenses.count) totaling \(money(report.expenses.total))")
        for category in report.expenses.byCategory.prefix(12) {
            print("  \(category.name): \(money(category.total)) (\(category.count))")
        }
        if report.expenses.byCategory.count > 12 {
            print("  \(Terminal.dim)… \(report.expenses.byCategory.count - 12) more categories (use --export for the full list)\(Terminal.reset)")
        }
        if report.expenses.missingVendorCount > 0 {
            print("  \(Terminal.brightYellow)\(report.expenses.missingVendorCount) expense(s) missing a vendor\(Terminal.reset)")
        }

        if let inventory = report.inventory {
            print("\n\(Terminal.bold)Inventory / COGS\(Terminal.reset): \(money(inventory.purchasesTotal)) purchased")
            for account in inventory.byAccount {
                print("  \(account.name): \(money(account.total)) (\(account.count))")
            }
            print("  \(Terminal.dim)Year-end: run `zoho-bookkeeper cogs --year \(report.year) --ending-inventory <value>`\(Terminal.reset)")
        }

        if let documentation = report.documentation {
            let pct = Int(documentation.coverage * 100)
            print("\n\(Terminal.bold)Receipts (≥ \(money(documentation.threshold)))\(Terminal.reset): \(documentation.documentedCount)/\(documentation.checkedCount) documented (\(pct)%)")
            for expense in documentation.missing.prefix(10) {
                print("  \(Terminal.brightYellow)missing\(Terminal.reset) \(expense.date) \(expense.vendorName) \(money(expense.amount)) (\(expense.category))")
            }
            if documentation.missing.count > 10 {
                print("  \(Terminal.dim)… \(documentation.missing.count - 10) more (use --export)\(Terminal.reset)")
            }
        }
    }

    private func exportReport(_ report: TaxReadinessReport) throws -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zoho-ai-bookkeeper/reports/\(report.year)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try TaxReadinessReportFormatter.markdown(report)
            .write(to: dir.appendingPathComponent("tax-readiness.md"), atomically: true, encoding: .utf8)
        try TaxReadinessReportFormatter.categoriesCSV(report)
            .write(to: dir.appendingPathComponent("expenses-by-category.csv"), atomically: true, encoding: .utf8)
        if let documentation = report.documentation {
            try TaxReadinessReportFormatter.undocumentedCSV(documentation)
                .write(to: dir.appendingPathComponent("undocumented-expenses.csv"), atomically: true, encoding: .utf8)
        }
        return dir
    }
}

// MARK: - Gaps

struct Gaps: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Detect bank-feed outages: quiet periods far outside each account's normal cadence"
    )

    @OptionGroup var options: CommonOptions

    @Option(name: .long, help: "Year to analyze (default: current year)")
    var year: Int?

    @Option(name: .long, help: "Limit to one bank account ID")
    var account: String?

    func run() async throws {
        let config = try ConfigLoader.load()
        let client = try await createZohoClient(config: config, verbose: options.verbose)
        let analysisYear = year ?? Calendar.current.component(.year, from: Date())

        guard let rangeStart = GapDetector.parseDate("\(analysisYear)-01-01"),
              let rangeEndOfYear = GapDetector.parseDate("\(analysisYear)-12-31") else {
            throw ValidationError("Invalid year")
        }
        let rangeEnd = min(rangeEndOfYear, Date())

        print("Fetching bank accounts...")
        var bankAccounts = try await client.fetchBankAccounts()
        if let account {
            bankAccounts = bankAccounts.filter { $0.accountId == account }
        }

        let detector = GapDetector()
        var anyCritical = false

        for bankAccount in bankAccounts {
            let transactions = try await client.fetchTransactions(
                accountId: bankAccount.accountId,
                dateStart: "\(analysisYear)-01-01",
                dateEnd: "\(analysisYear)-12-31",
                status: .all
            )
            let report = detector.analyze(
                accountId: bankAccount.accountId,
                accountName: bankAccount.accountName,
                transactions: transactions,
                rangeStart: rangeStart,
                rangeEnd: rangeEnd
            )
            anyCritical = anyCritical || report.hasCriticalFindings

            print("\n\(Terminal.bold)\(bankAccount.accountName)\(Terminal.reset)  \(Terminal.dim)\(report.transactionCount) tx" +
                (report.medianIntervalDays.map { ", ~every \($0)d" } ?? "") + "\(Terminal.reset)")
            print("  \(sparkline(report.weeklyCounts))  \(Terminal.dim)Jan → Dec, weekly\(Terminal.reset)")

            if report.findings.isEmpty {
                print("  \(Terminal.brightGreen)✓ no gaps detected\(Terminal.reset)")
            } else {
                for finding in report.findings {
                    let color = finding.severity == .critical ? Terminal.brightRed : Terminal.brightYellow
                    print("  \(color)⚠ \(finding.summary)\(Terminal.reset)")
                }
            }
        }

        if anyCritical {
            throw ExitCode(2)
        }
    }

    private func sparkline(_ counts: [Int]) -> String {
        let blocks = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
        guard let maxCount = counts.max(), maxCount > 0 else {
            return String(repeating: "▁", count: counts.count)
        }
        return counts.map { count in
            count == 0 ? "\(Terminal.brightRed)▁\(Terminal.reset)"
                       : blocks[min((count * blocks.count - 1) / maxCount, blocks.count - 1)]
        }.joined()
    }
}

// MARK: - COGS

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
