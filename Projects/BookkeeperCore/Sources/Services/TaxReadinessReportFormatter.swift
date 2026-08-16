import Foundation
import ZohoBooksClient

/// Renders a `TaxReadinessReport` for humans and spreadsheets. Shared by the
/// CLI's export command and (eventually) app-side share sheets.
public enum TaxReadinessReportFormatter {

    public static func markdown(_ report: TaxReadinessReport) -> String {
        var lines: [String] = []
        lines.append("# Tax readiness — FY\(report.year)")
        lines.append("")
        lines.append("_Generated \(ISO8601DateFormatter().string(from: report.generatedAt))_")
        lines.append("")

        if report.blockers.isEmpty {
            lines.append("**✅ No blockers found.**")
        } else {
            lines.append("## Blockers")
            lines.append("")
            for blocker in report.blockers {
                lines.append("- ⚠️ \(blocker)")
            }
        }
        lines.append("")

        lines.append("## Accounts")
        lines.append("")
        lines.append("| Account | Transactions | Uncategorized | Gap findings |")
        lines.append("|---|---|---|---|")
        for account in report.accounts {
            let gaps = account.gaps.findings.isEmpty
                ? "—"
                : account.gaps.findings.map(\.summary).joined(separator: "<br>")
            lines.append("| \(account.accountName) | \(account.transactionCount) | \(account.uncategorizedCount) | \(gaps) |")
        }
        lines.append("")

        lines.append("## Expenses by category")
        lines.append("")
        lines.append("| Category | Count | Total |")
        lines.append("|---|---|---|")
        for category in report.expenses.byCategory {
            lines.append("| \(category.name) | \(category.count) | \(money(category.total)) |")
        }
        lines.append("| **Total** | \(report.expenses.count) | **\(money(report.expenses.total))** |")
        if report.expenses.missingVendorCount > 0 {
            lines.append("")
            lines.append("\(report.expenses.missingVendorCount) expense(s) have no vendor set.")
        }
        lines.append("")

        if let inventory = report.inventory {
            lines.append("## Inventory / COGS activity")
            lines.append("")
            lines.append("Purchases recorded to inventory/COGS accounts (not period expenses — deducted via COGS when sold):")
            lines.append("")
            for account in inventory.byAccount {
                lines.append("- \(account.name): \(account.count) purchase(s), \(money(account.total))")
            }
            lines.append("- **Total purchases: \(money(inventory.purchasesTotal))**")
            lines.append("")
            lines.append("Year-end: COGS = beginning inventory + \(money(inventory.purchasesTotal)) − ending inventory (run `zoho-bookkeeper cogs`).")
            lines.append("")
        }

        if let documentation = report.documentation {
            lines.append("## Receipt documentation (≥ \(money(documentation.threshold)))")
            lines.append("")
            lines.append("\(documentation.documentedCount)/\(documentation.checkedCount) documented (\(Int(documentation.coverage * 100))%).")
            if !documentation.missing.isEmpty {
                lines.append("")
                lines.append("| Date | Vendor | Category | Amount |")
                lines.append("|---|---|---|---|")
                for expense in documentation.missing {
                    lines.append("| \(expense.date) | \(expense.vendorName) | \(expense.category) | \(money(expense.amount)) |")
                }
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// Expenses-by-category CSV for the accountant.
    public static func categoriesCSV(_ report: TaxReadinessReport) -> String {
        var rows = ["category,count,total"]
        for category in report.expenses.byCategory {
            rows.append("\(csvEscape(category.name)),\(category.count),\(String(format: "%.2f", category.total))")
        }
        if let inventory = report.inventory {
            for account in inventory.byAccount {
                rows.append("\(csvEscape(account.name + " (inventory)")),\(account.count),\(String(format: "%.2f", account.total))")
            }
        }
        return rows.joined(separator: "\n") + "\n"
    }

    /// Undocumented-expenses CSV (present when the receipt check ran).
    public static func undocumentedCSV(_ documentation: TaxReadinessReport.DocumentationSummary) -> String {
        var rows = ["date,vendor,category,amount,expense_id"]
        for expense in documentation.missing {
            rows.append([
                expense.date,
                csvEscape(expense.vendorName),
                csvEscape(expense.category),
                String(format: "%.2f", expense.amount),
                expense.expenseId,
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    // MARK: - Helpers

    public static func money(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    private static func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}

/// Which chart-of-accounts entries a spend can be categorized against.
/// Period expenses plus inventory/COGS accounts (inventory purchases are
/// recorded as assets at purchase time; see CLAUDE.md on LEGO/COGS handling).
public enum CategoryFilter {
    public static func spendingCategories(from accounts: [ZBAccount]) -> [String] {
        accounts
            .filter { account in
                let type = (account.accountType ?? "").lowercased()
                if ["expense", "cost_of_goods_sold", "stock"].contains(type) { return true }
                return (account.accountName ?? "").lowercased().contains("inventory")
            }
            .compactMap { $0.accountName }
            .sorted()
    }
}
