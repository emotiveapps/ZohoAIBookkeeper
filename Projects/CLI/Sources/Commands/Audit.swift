import ArgumentParser
import Foundation
import ZohoBooksClient
import BookkeeperCore

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

    @Flag(name: .long, help: "Write markdown + CSV to <output>/<year>/ (default: ./reports/<year>/)")
    var export: Bool = false

    @Option(name: .long, help: "Directory to export reports into (default: ./reports)")
    var output: String = "reports"

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
        let base = URL(fileURLWithPath: output, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        let dir = base.appendingPathComponent("\(report.year)")
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
