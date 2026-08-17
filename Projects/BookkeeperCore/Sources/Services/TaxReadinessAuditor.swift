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

/// Runs the per-year completeness audit against Zoho.
public actor TaxReadinessAuditor {
    private let client: ZohoBooksClient<ZohoOAuth>
    private let gapDetector: GapDetector

    public init(client: ZohoBooksClient<ZohoOAuth>, gapDetector: GapDetector = GapDetector()) {
        self.client = client
        self.gapDetector = gapDetector
    }

    /// - Parameters:
    ///   - checkDocumentation: also fetch expense details to verify receipts are
    ///     attached (one API call per expense ≥ `receiptThreshold` — slow on
    ///     large years, hence opt-in).
    ///   - progress: called with human-readable status lines as the audit runs.
    public func audit(
        year: Int,
        checkDocumentation: Bool = false,
        receiptThreshold: Double = 75,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> TaxReadinessReport {
        let dateStart = "\(year)-01-01"
        let dateEnd = "\(year)-12-31"
        guard let rangeStart = GapDetector.parseDate(dateStart),
              let rangeEndOfYear = GapDetector.parseDate(dateEnd) else {
            throw ConfigurationError.invalidFormat("Invalid year \(year)")
        }
        // Don't treat the not-yet-happened part of the current year as a gap.
        let rangeEnd = min(rangeEndOfYear, Date())

        progress?("Fetching bank accounts…")
        let bankAccounts = try await client.fetchBankAccounts()

        var accountAudits: [TaxReadinessReport.AccountAudit] = []
        for account in bankAccounts {
            progress?("Scanning \(account.accountName)…")
            // Zoho ignores date_start/date_end when filter_by is Status.All,
            // so scope to the year client-side (GapDetector filters again
            // internally; the counts below must match what it sees).
            let transactions = try await client.fetchTransactions(
                accountId: account.accountId,
                dateStart: dateStart,
                dateEnd: dateEnd,
                status: .all
            ).filter { transaction in
                guard let date = GapDetector.parseDate(transaction.date) else { return false }
                return date >= rangeStart && date <= rangeEndOfYear
            }
            let uncategorized = transactions.filter {
                ($0.status ?? "").lowercased() == "uncategorized"
            }
            let gaps = gapDetector.analyze(
                accountId: account.accountId,
                accountName: account.accountName,
                transactions: transactions,
                rangeStart: rangeStart,
                rangeEnd: rangeEnd
            )
            accountAudits.append(TaxReadinessReport.AccountAudit(
                accountId: account.accountId,
                accountName: account.accountName,
                accountType: account.accountType,
                transactionCount: transactions.count,
                uncategorizedCount: uncategorized.count,
                gaps: gaps
            ))
        }

        progress?("Fetching \(year) expenses…")
        let expenses = try await client.fetchExpenses(dateStart: dateStart, dateEnd: dateEnd)

        progress?("Fetching chart of accounts…")
        let chartAccounts = try await client.fetchAccounts()
        let inventoryAccountNames = Self.inventoryAccountNames(in: chartAccounts)

        let (expenseSummary, inventorySummary) = Self.summarize(
            expenses: expenses,
            inventoryAccountNames: inventoryAccountNames
        )

        var documentation: TaxReadinessReport.DocumentationSummary?
        if checkDocumentation {
            documentation = try await checkReceipts(
                expenses: expenses,
                threshold: receiptThreshold,
                progress: progress
            )
        }

        return TaxReadinessReport(
            year: year,
            generatedAt: Date(),
            accounts: accountAudits.sorted { $0.accountName < $1.accountName },
            expenses: expenseSummary,
            inventory: inventorySummary,
            documentation: documentation
        )
    }

    // MARK: - Pure summarization (public: the CLI cogs command reuses these)

    /// Chart accounts that hold inventory or COGS — purchases categorized here
    /// are asset/COGS activity, not period expenses.
    public static func inventoryAccountNames(in accounts: [ZBAccount]) -> Set<String> {
        Set(accounts.compactMap { account -> String? in
            guard let name = account.accountName else { return nil }
            let type = (account.accountType ?? "").lowercased()
            if type == "stock" || type == "cost_of_goods_sold" { return name }
            if name.lowercased().contains("inventory") { return name }
            return nil
        })
    }

    public static func summarize(
        expenses: [ZBExpense],
        inventoryAccountNames: Set<String>
    ) -> (TaxReadinessReport.ExpenseSummary, TaxReadinessReport.InventorySummary?) {
        var byCategory: [String: (count: Int, total: Double)] = [:]
        var inventoryByAccount: [String: (count: Int, total: Double)] = [:]
        var missingVendor = 0
        var expenseCount = 0
        var expenseTotal = 0.0

        for expense in expenses {
            let category = expense.accountName ?? "(no category)"
            let amount = expense.total ?? expense.amount ?? 0

            if inventoryAccountNames.contains(category) {
                var entry = inventoryByAccount[category] ?? (0, 0)
                entry.count += 1
                entry.total += amount
                inventoryByAccount[category] = entry
                continue
            }

            expenseCount += 1
            expenseTotal += amount
            var entry = byCategory[category] ?? (0, 0)
            entry.count += 1
            entry.total += amount
            byCategory[category] = entry

            if (expense.vendorName ?? "").isEmpty {
                missingVendor += 1
            }
        }

        func totals(_ dict: [String: (count: Int, total: Double)]) -> [TaxReadinessReport.CategoryTotal] {
            dict
                .map { TaxReadinessReport.CategoryTotal(name: $0.key, count: $0.value.count, total: $0.value.total) }
                .sorted { ($0.total, $1.name) > ($1.total, $0.name) }
        }

        let summary = TaxReadinessReport.ExpenseSummary(
            count: expenseCount,
            total: expenseTotal,
            missingVendorCount: missingVendor,
            byCategory: totals(byCategory)
        )

        let inventory: TaxReadinessReport.InventorySummary? = inventoryByAccount.isEmpty ? nil :
            TaxReadinessReport.InventorySummary(
                byAccount: totals(inventoryByAccount),
                purchasesTotal: inventoryByAccount.values.reduce(0) { $0 + $1.total }
            )

        return (summary, inventory)
    }

    // MARK: - Receipt check

    private func checkReceipts(
        expenses: [ZBExpense],
        threshold: Double,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> TaxReadinessReport.DocumentationSummary {
        let candidates = expenses.filter { ($0.total ?? $0.amount ?? 0) >= threshold }
        var documented = 0
        var missing: [TaxReadinessReport.UndocumentedExpense] = []

        for (index, expense) in candidates.enumerated() {
            guard let expenseId = expense.expenseId else { continue }
            if index.isMultiple(of: 20) {
                progress?("Checking receipts… \(index)/\(candidates.count)")
            }
            let detail = try await client.fetchExpense(expenseId: expenseId)
            if let documents = detail.documents, !documents.isEmpty {
                documented += 1
            } else {
                missing.append(TaxReadinessReport.UndocumentedExpense(
                    expenseId: expenseId,
                    date: expense.date ?? "",
                    vendorName: expense.vendorName ?? "(no vendor)",
                    category: expense.accountName ?? "(no category)",
                    amount: expense.total ?? expense.amount ?? 0
                ))
            }
        }

        return TaxReadinessReport.DocumentationSummary(
            threshold: threshold,
            checkedCount: candidates.count,
            documentedCount: documented,
            missing: missing.sorted { $0.amount > $1.amount }
        )
    }
}
