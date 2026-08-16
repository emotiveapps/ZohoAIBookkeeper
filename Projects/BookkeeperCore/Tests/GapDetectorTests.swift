import Foundation
import Testing
import ZohoBooksClient
@testable import BookkeeperCore

private func tx(_ date: String) -> ZBBankTransaction {
    ZBBankTransaction(transactionId: UUID().uuidString, date: date, amount: 10, debitOrCredit: "debit")
}

/// Daily-ish transactions from `start`, one every `stride` days, `count` times.
private func regularDates(from start: String, stride strideDays: Int, count: Int) -> [ZBBankTransaction] {
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")!
    formatter.dateFormat = "yyyy-MM-dd"
    let startDate = formatter.date(from: start)!
    return (0 ..< count).map { i in
        tx(formatter.string(from: calendar.date(byAdding: .day, value: i * strideDays, to: startDate)!))
    }
}

private let jan1 = GapDetector.parseDate("2025-01-01")!
private let dec31 = GapDetector.parseDate("2025-12-31")!

@Suite("GapDetector")
struct GapDetectorTests {

    private func analyze(_ transactions: [ZBBankTransaction], detector: GapDetector = GapDetector()) -> AccountGapReport {
        detector.analyze(
            accountId: "a1",
            accountName: "Test",
            transactions: transactions,
            rangeStart: jan1,
            rangeEnd: dec31
        )
    }

    @Test("A busy account with a mid-year outage is flagged")
    func midYearOutage() {
        // Weekly activity Jan–May, silence Jun–Aug, weekly again Sep–Dec.
        var transactions = regularDates(from: "2025-01-01", stride: 7, count: 20) // Jan 1 – May 14
        transactions += regularDates(from: "2025-09-01", stride: 7, count: 17)   // Sep 1 – Dec 22

        let report = analyze(transactions)
        let silent = report.findings.filter { $0.kind == .silentWindow }
        #expect(silent.count == 1)
        #expect(silent.first?.days ?? 0 > 100)
        #expect(silent.first?.severity == .critical)
    }

    @Test("Steady activity produces no findings")
    func steadyActivity() {
        let report = analyze(regularDates(from: "2025-01-01", stride: 7, count: 52))
        #expect(report.findings.isEmpty)
        #expect(report.medianIntervalDays == 7)
    }

    @Test("Sparse accounts need proportionally longer silences to flag")
    func sparseAccountTolerance() {
        // Monthly cadence: a 3-month quiet stretch is only ~3× cadence — not flagged
        // at the default 5× multiplier.
        var transactions = regularDates(from: "2025-01-15", stride: 30, count: 5) // Jan–May
        transactions += regularDates(from: "2025-09-15", stride: 30, count: 4)    // Sep–Dec
        let report = analyze(transactions)
        #expect(report.findings.filter { $0.kind == .silentWindow }.isEmpty)
    }

    @Test("Near-dormant accounts are never flagged")
    func dormantAccount() {
        #expect(analyze([]).findings.isEmpty)
        #expect(analyze([tx("2025-03-01")]).findings.isEmpty)
        #expect(analyze([tx("2025-03-01"), tx("2025-11-01")]).findings.isEmpty)
    }

    @Test("A feed that dies before range end is reported stale")
    func staleFeed() {
        // Weekly activity that stops at the end of June.
        let report = analyze(regularDates(from: "2025-01-01", stride: 7, count: 26))
        let stale = report.findings.filter { $0.kind == .staleFeed }
        #expect(stale.count == 1)
        #expect(stale.first?.severity == .critical)
    }

    @Test("A feed connected late in the year is reported as a late start")
    func lateStart() {
        let report = analyze(regularDates(from: "2025-06-01", stride: 7, count: 31))
        let late = report.findings.filter { $0.kind == .lateStart }
        #expect(late.count == 1)
        #expect(late.first?.days == 151)
    }

    @Test("Weekly counts cover the whole range for sparklines")
    func weeklyCounts() {
        let report = analyze(regularDates(from: "2025-01-01", stride: 7, count: 10))
        #expect(report.weeklyCounts.count == 53) // 364 days / 7 + 1
        #expect(report.weeklyCounts.prefix(10).allSatisfy { $0 == 1 })
        #expect(report.weeklyCounts.suffix(10).allSatisfy { $0 == 0 })
    }

    @Test("Transactions outside the range are ignored")
    func rangeFiltering() {
        var transactions = regularDates(from: "2025-01-01", stride: 7, count: 52)
        transactions.append(tx("2024-06-15"))
        transactions.append(tx("2026-02-01"))
        let report = analyze(transactions)
        #expect(report.transactionCount == 52)
    }
}

@Suite("TaxReadinessAuditor summarization")
struct TaxReadinessSummaryTests {

    private func expense(category: String?, amount: Double, vendor: String? = "Acme") -> ZBExpense {
        ZBExpense(accountName: category, vendorName: vendor, amount: amount, total: amount)
    }

    @Test("Inventory accounts are split out of period expenses")
    func inventorySplit() {
        let expenses = [
            expense(category: "Software", amount: 100),
            expense(category: "Inventory Asset", amount: 500),
            expense(category: "Inventory Asset", amount: 300),
            expense(category: "Cost of Goods Sold", amount: 200),
        ]
        let (summary, inventory) = TaxReadinessAuditor.summarize(
            expenses: expenses,
            inventoryAccountNames: ["Inventory Asset", "Cost of Goods Sold"]
        )
        #expect(summary.count == 1)
        #expect(summary.total == 100)
        #expect(inventory?.purchasesTotal == 1000)
        #expect(inventory?.byAccount.first?.name == "Inventory Asset")
        #expect(inventory?.cogs(beginningInventory: 2000, endingInventory: 2500) == 500)
    }

    @Test("Missing vendors are counted; categories sorted by spend")
    func vendorAndCategoryTotals() {
        let expenses = [
            expense(category: "Meals", amount: 50, vendor: nil),
            expense(category: "Software", amount: 500),
            expense(category: "Meals", amount: 30, vendor: ""),
        ]
        let (summary, inventory) = TaxReadinessAuditor.summarize(expenses: expenses, inventoryAccountNames: [])
        #expect(inventory == nil)
        #expect(summary.missingVendorCount == 2)
        #expect(summary.byCategory.map(\.name) == ["Software", "Meals"])
        #expect(summary.byCategory.last?.count == 2)
    }

    @Test("Inventory chart accounts are recognized by type and by name")
    func inventoryAccountDetection() {
        let accounts = [
            ZBAccount(accountId: "1", accountName: "Inventory Asset", accountType: "stock"),
            ZBAccount(accountId: "2", accountName: "Cost of Goods Sold", accountType: "cost_of_goods_sold"),
            ZBAccount(accountId: "3", accountName: "LEGO Inventory", accountType: "other_current_asset"),
            ZBAccount(accountId: "4", accountName: "Software", accountType: "expense"),
        ]
        let names = TaxReadinessAuditor.inventoryAccountNames(in: accounts)
        #expect(names == ["Inventory Asset", "Cost of Goods Sold", "LEGO Inventory"])
    }
}
