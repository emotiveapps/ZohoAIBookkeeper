import Foundation
import ZohoBooksClient


/// Everything the owner needs to know before filing a year's taxes.
public struct TaxReadinessReport: Sendable {
    public struct AccountAudit: Sendable {
        public let accountId: String
        public let accountName: String
        public let accountType: String
        public let transactionCount: Int
        public let uncategorizedCount: Int
        public let gaps: AccountGapReport
    }

    public struct CategoryTotal: Sendable {
        public let name: String
        public let count: Int
        public let total: Double
    }

    public struct ExpenseSummary: Sendable {
        public let count: Int
        public let total: Double
        public let missingVendorCount: Int
        public let byCategory: [CategoryTotal]
    }

    public struct InventorySummary: Sendable {
        /// Purchases categorized to inventory/COGS accounts during the year.
        public let byAccount: [CategoryTotal]
        public let purchasesTotal: Double

        /// Periodic COGS: beginning inventory + purchases − ending inventory.
        public func cogs(beginningInventory: Double, endingInventory: Double) -> Double {
            beginningInventory + purchasesTotal - endingInventory
        }
    }

    public struct UndocumentedExpense: Sendable {
        public let expenseId: String
        public let date: String
        public let vendorName: String
        public let category: String
        public let amount: Double
    }

    public struct DocumentationSummary: Sendable {
        public let threshold: Double
        public let checkedCount: Int
        public let documentedCount: Int
        public let missing: [UndocumentedExpense]

        public var coverage: Double {
            checkedCount > 0 ? Double(documentedCount) / Double(checkedCount) : 1
        }
    }

    public let year: Int
    public let generatedAt: Date
    public let accounts: [AccountAudit]
    public let expenses: ExpenseSummary
    public let inventory: InventorySummary?
    /// Present only when the (API-expensive) receipt check was requested.
    public let documentation: DocumentationSummary?

    public var totalUncategorized: Int {
        accounts.reduce(0) { $0 + $1.uncategorizedCount }
    }

    /// Things that should be fixed before filing.
    public var blockers: [String] {
        var result: [String] = []
        if totalUncategorized > 0 {
            let affected = accounts.filter { $0.uncategorizedCount > 0 }.count
            result.append("\(totalUncategorized) uncategorized transaction(s) across \(affected) account(s)")
        }
        // Expenses dumped into a literal "Uncategorized" category are just as
        // unfiled as uncategorized bank transactions.
        if let uncategorized = expenses.byCategory.first(where: { $0.name.lowercased() == "uncategorized" }) {
            result.append("\(uncategorized.count) expense(s) totaling \(TaxReadinessReportFormatter.money(uncategorized.total)) in the \"Uncategorized\" category")
        }
        for account in accounts where account.gaps.hasCriticalFindings {
            for finding in account.gaps.findings where finding.severity == .critical {
                result.append("\(account.accountName): \(finding.summary)")
            }
        }
        if let documentation, !documentation.missing.isEmpty {
            result.append("\(documentation.missing.count) expense(s) ≥ $\(Int(documentation.threshold)) without receipt documentation")
        }
        return result
    }
}

