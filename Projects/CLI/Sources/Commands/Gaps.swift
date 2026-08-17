import ArgumentParser
import Foundation
import ZohoBooksClient
import BookkeeperCore


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

