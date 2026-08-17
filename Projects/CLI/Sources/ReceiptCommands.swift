import ArgumentParser
import Foundation
import ZohoBooksClient
import BookkeeperCore

struct Receipts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Capture emailed receipts and attach them to Zoho expenses as audit documentation",
        subcommands: [Login.self, Sync.self, List.self, Attach.self],
        defaultSubcommand: Sync.self
    )

    static func mailboxes(from config: FullConfiguration) throws -> [GraphMailboxConfig] {
        guard let mailboxes = config.receipts?.mailboxes, !mailboxes.isEmpty else {
            throw ValidationError(
                "No receipt mailboxes configured. Add a \"receipts\" section to config.json (see config.example.json)."
            )
        }
        return mailboxes
    }

    // MARK: - Login

    struct Login: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Sign in to the configured Microsoft 365 mailboxes (device-code flow)"
        )

        @Flag(name: .long, help: "Sign in again even if credentials exist")
        var force: Bool = false

        func run() async throws {
            let config = try ConfigLoader.load()
            for mailbox in try Receipts.mailboxes(from: config) {
                let graph = GraphMailClient(config: mailbox)
                if await graph.isSignedIn && !force {
                    print("✓ \(mailbox.address): already signed in (use --force to redo)")
                    continue
                }

                print("\nSigning in for \(Terminal.bold)\(mailbox.address)\(Terminal.reset)")
                print("Use an account that has Full Access to this shared mailbox.\n")
                let code = try await graph.beginDeviceLogin()
                print("  \(Terminal.brightCyan)\(code.message)\(Terminal.reset)\n")
                print("Waiting for you to finish signing in…")
                try await graph.waitForLogin(code)
                print("\(Terminal.brightGreen)✓ Signed in for \(mailbox.address)\(Terminal.reset)")
            }
        }
    }

    // MARK: - Sync

    struct Sync: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Pull new receipt emails, parse them, and attach matches to Zoho expenses"
        )

        @OptionGroup var options: CommonOptions

        @Flag(name: .long, help: "Show what would happen without writing anything")
        var dryRun: Bool = false

        @Option(name: .long, help: "Re-scan mail from this date (yyyy-MM-dd) instead of the last sync point")
        var since: String?

        func run() async throws {
            let config = try ConfigLoader.load()
            let zoho = try await createZohoClient(config: config, verbose: options.verbose)
            let parser = ReceiptParser(apiKey: config.anthropic.apiKey)
            let store = try ReceiptStore()

            let sinceDate: Date?
            if let since {
                guard let parsed = GapDetector.parseDate(since) else {
                    throw ValidationError("--since must be yyyy-MM-dd")
                }
                sinceDate = parsed
            } else {
                sinceDate = nil
            }

            for mailbox in try Receipts.mailboxes(from: config) {
                print("\n\(Terminal.bold)\(mailbox.address)\(Terminal.reset)")
                let graph = GraphMailClient(config: mailbox)
                let pipeline = ReceiptPipeline(graph: graph, parser: parser, store: store, zoho: zoho)

                let summary = try await pipeline.sync(dryRun: dryRun, since: sinceDate)
                for line in summary.lines {
                    print("  \(line)")
                }
                print("  \(Terminal.dim)\(summary.messagesSeen) message(s) scanned\(Terminal.reset)")
                print("  \(Terminal.brightGreen)\(summary.matched) matched\(Terminal.reset) · \(Terminal.brightYellow)\(summary.ambiguous) ambiguous\(Terminal.reset) · \(summary.pending) pending · \(summary.newReceipts) new receipt(s)")
            }

            print("\nArchive: \(try ReceiptStore().rootURL.path)")
        }
    }

    // MARK: - List

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List archived receipts and their match status"
        )

        @Option(name: .long, help: "Filter by status: pending | ambiguous | matched | skipped")
        var status: String?

        func run() async throws {
            let store = try ReceiptStore()
            var records = await store.allRecords()
            if let status {
                guard let filter = ReceiptStatus(rawValue: status) else {
                    throw ValidationError("Unknown status \"\(status)\"")
                }
                records = records.filter { $0.status == filter }
            }

            guard !records.isEmpty else {
                print("No receipts\(status.map { " with status \($0)" } ?? "") in the archive.")
                return
            }

            func pad(_ value: String, _ width: Int) -> String {
                String(value.prefix(width)).padding(toLength: width, withPad: " ", startingAt: 0)
            }

            print("\(pad("ID", 10))\(pad("DATE", 12))\(pad("VENDOR", 26))\(pad("TOTAL", 11))STATUS")
            print(String(repeating: "─", count: 70))
            for record in records {
                let statusLabel: String
                switch record.status {
                case .matched: statusLabel = "\(Terminal.brightGreen)matched\(Terminal.reset)"
                case .ambiguous: statusLabel = "\(Terminal.brightYellow)ambiguous (\(record.candidateExpenseIds.count))\(Terminal.reset)"
                case .pending: statusLabel = "pending"
                case .skipped: statusLabel = "\(Terminal.dim)skipped\(Terminal.reset)"
                }
                let total = record.parsed?.total.map { String(format: "%.2f", $0) } ?? "—"
                print(
                    pad(String(record.id.prefix(8)), 10)
                        + pad(record.parsed?.date ?? "—", 12)
                        + pad(record.parsed?.vendor ?? "—", 26)
                        + pad(total, 11)
                        + statusLabel
                )
            }
        }
    }

    // MARK: - Attach

    struct Attach: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manually attach a receipt to a Zoho expense (resolves ambiguous/pending receipts)"
        )

        @OptionGroup var options: CommonOptions

        @Option(name: .long, help: "Receipt ID prefix (from `receipts list`)")
        var id: String

        @Option(name: .long, help: "Zoho expense ID to attach to")
        var expense: String

        func run() async throws {
            let config = try ConfigLoader.load()
            let zoho = try await createZohoClient(config: config, verbose: options.verbose)
            let store = try ReceiptStore()

            guard let record = await store.record(idPrefix: id) else {
                throw ValidationError("No unique receipt matches ID prefix \"\(id)\" — check `receipts list`.")
            }

            // Validate the expense exists before uploading.
            let detail = try await zoho.fetchExpense(expenseId: expense)

            let fileData = try await store.fileData(for: record)
            let filename = (record.relativePath as NSString).lastPathComponent
            try await zoho.uploadExpenseAttachment(expenseId: expense, fileData: fileData, filename: filename)

            var updated = record
            updated.status = .matched
            updated.matchedExpenseId = expense
            updated.attachedToZoho = true
            updated.candidateExpenseIds = []
            try await store.update(updated)

            print("\(Terminal.brightGreen)✓\(Terminal.reset) Attached \(record.parsed?.vendor ?? record.id) to \(detail.vendorName ?? "expense") (\(detail.date ?? "")) \(TaxReadinessReportFormatter.money(detail.total ?? detail.amount ?? 0))")
        }
    }
}
