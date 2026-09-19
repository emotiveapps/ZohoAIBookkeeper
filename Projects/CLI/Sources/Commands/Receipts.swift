import ArgumentParser
import Foundation
import ZohoBooksClient
import BookkeeperCore

struct Receipts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Capture emailed receipts and attach them to Zoho expenses as audit documentation",
        subcommands: [Login.self, Sync.self, Retry.self, List.self, Attach.self],
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

    /// The receipt archive: cloud-canonical in OneDrive
    /// (`receipts.archive_folder_path`), synced through a
    /// `GraphDriveSyncEngine` with the local cache in `~/Library/Caches` and
    /// pending uploads staged in `~/Library/Application Support`.
    static func store(for config: FullConfiguration) throws -> ReceiptStore {
        guard let receipts = config.receipts, let mailbox = receipts.mailboxes.first else {
            throw ValidationError(
                "The receipt archive is cloud-canonical and needs a \"receipts\" section "
                    + "(Microsoft sign-in) in config.json."
            )
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let engine = try GraphDriveSyncEngine(
            graph: MicrosoftGraphMailClient(config: mailbox),
            folderPath: receipts.resolvedArchiveFolderPath,
            cacheRoot: caches.appendingPathComponent("com.emotiveapps.ZohoBookkeeper/ReceiptsArchive"),
            stagingRoot: support.appendingPathComponent("com.emotiveapps.ZohoBookkeeper/ArchiveStaging"),
            syncState: try syncState()
        )
        return ReceiptStore(engine: engine)
    }

    /// Sync bookkeeping lives in state.json next to config.json (repo root,
    /// gitignored) — operational state, not audit data.
    static func syncState() throws -> FileSyncState {
        try FileSyncState(
            url: ConfigLoader.configURL().deletingLastPathComponent().appendingPathComponent("state.json")
        )
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
                let graph = MicrosoftGraphMailClient(config: mailbox)
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
            abstract: "Pull new receipt emails, parse them, and attach matches to Zoho expenses",
            discussion: """
                By default this only processes what is new: the mailbox Inbox and \
                the OneDrive folder. Previously unmatched receipts are left alone, \
                because re-checking every one of them against Zoho is what makes a \
                sync slow once the archive is large.

                Use --retry to also re-check recent pendings, or --full after \
                importing a backlog (a stack of scanned paper receipts, a late \
                statement) to re-check every pending receipt regardless of age.
                """
        )

        @OptionGroup var options: CommonOptions

        @Flag(name: .long, help: "Show what would happen without writing anything")
        var dryRun: Bool = false

        @Option(name: .long, help: "Re-scan mail from this date (yyyy-MM-dd) instead of the last sync point")
        var since: String?

        @Flag(name: .long, help: "Also re-check recent pending receipts against Zoho")
        var retry: Bool = false

        @Flag(name: .long, help: "Re-check every pending receipt, however old (use after importing a backlog)")
        var full: Bool = false

        func run() async throws {
            let config = try ConfigLoader.load()
            let zoho = try await createZohoClient(config: config, verbose: options.verbose)
            let parser = ReceiptParser(apiKey: config.anthropic.apiKey)
            let store = try Receipts.store(for: config)

            // Cloud-canonical archive: pull other devices' work first so
            // matching and dedupe see it; push local changes at the end.
            if let engine = await store.syncEngine {
                let report = try await engine.pull()
                print("\(Terminal.dim)archive pull: \(report.downloaded) downloaded\(Terminal.reset)")
                for warning in report.warnings { print("  \(Terminal.brightYellow)\(warning)\(Terminal.reset)") }
            }

            let sinceDate = try parsedSince()

            // Every sync skips its own retry pass; one shared pass runs at the
            // end instead (the retry pass is the Zoho-API-heavy part).
            let onedrive = config.receipts?.onedrive
            var lastPipeline: ReceiptPipeline?
            for mailbox in try Receipts.mailboxes(from: config) {
                print("\n\(Terminal.bold)\(mailbox.address)\(Terminal.reset)")
                let graph = MicrosoftGraphMailClient(config: mailbox)
                let pipeline = ReceiptPipeline(
                    graph: graph,
                    driveFolder: onedrive?.folderPath,
                    parser: parser,
                    store: store,
                    syncState: try Receipts.syncState(),
                    zoho: zoho
                )
                lastPipeline = pipeline

                let summary = try await pipeline.sync(dryRun: dryRun, since: sinceDate, runRetryPass: false)
                Receipts.printSummary(summary, scanned: "message(s)")
            }

            if let onedrive {
                let mailboxes = try Receipts.mailboxes(from: config)
                let auth = mailboxes.first { onedrive.tenantId == nil || $0.tenantId == onedrive.tenantId }
                    ?? mailboxes[0]
                print("\n\(Terminal.bold)OneDrive: \(onedrive.folderPath)\(Terminal.reset)")
                let pipeline = ReceiptPipeline(
                    graph: MicrosoftGraphMailClient(config: auth),
                    driveFolder: onedrive.folderPath,
                    parser: parser,
                    store: store,
                    syncState: try Receipts.syncState(),
                    zoho: zoho
                )
                lastPipeline = pipeline
                let summary = try await pipeline.syncDrive(dryRun: dryRun, runRetryPass: false)
                Receipts.printSummary(summary, scanned: "file(s)")
            }

            if !dryRun {
                try await runRetryPass(lastPipeline)
            }

            if let engine = await store.syncEngine {
                let report = try await engine.push()
                print("\n\(Terminal.dim)archive push: \(report.uploaded) uploaded\(Terminal.reset)")
                for warning in report.warnings { print("  \(Terminal.brightYellow)\(warning)\(Terminal.reset)") }
            }

            print("\nArchive cache: \(store.rootURL.path)")
        }

        private func parsedSince() throws -> Date? {
            guard let since else { return nil }
            guard let parsed = GapDetector.parseDate(since) else {
                throw ValidationError("--since must be yyyy-MM-dd")
            }
            return parsed
        }

        /// The retry pass is the Zoho-API-heavy part — one expense fetch per
        /// pending receipt — so it is opt-in. New mail is matched either way.
        private func runRetryPass(_ pipeline: ReceiptPipeline?) async throws {
            guard let pipeline, retry || full else {
                print(
                    "\n\(Terminal.dim)Pending receipts not re-checked"
                        + " (--retry, or --full after a backlog import)\(Terminal.reset)"
                )
                return
            }
            print("\n\(Terminal.bold)Retry pass\(full ? " (full)" : "")\(Terminal.reset)")
            let summary = try await pipeline.retryPending(policy: full ? .exhaustive : .standard)
            Receipts.printSummary(summary, scanned: "receipt(s)")
        }
    }

    // MARK: - Retry

    struct Retry: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Re-check pending receipts against Zoho and attach any that now match",
            discussion: """
                A pending receipt is one that is archived but has no Zoho expense \
                to attach it to yet — usually because the bank feed hasn't caught \
                up. This pass looks again.

                By default it only re-checks receipts that still plausibly have an \
                expense coming (recent, and not already tried several times). Pass \
                --all to re-check every pending receipt however old: the run to make \
                after scanning in a stack of paper receipts, or after importing a \
                statement that finally recorded the expenses.
                """
        )

        @OptionGroup var options: CommonOptions

        @Flag(name: .long, help: "Re-check every pending receipt, however old or often tried")
        var all: Bool = false

        @Flag(name: .long, help: "Clear the per-receipt attempt counts before retrying")
        var resetBudget: Bool = false

        func run() async throws {
            let config = try ConfigLoader.load()
            let zoho = try await createZohoClient(config: config, verbose: options.verbose)
            let store = try Receipts.store(for: config)

            guard let mailbox = config.receipts?.mailboxes.first else {
                throw ValidationError("No receipt mailboxes configured.")
            }

            if let engine = await store.syncEngine {
                let report = try await engine.pull()
                print("\(Terminal.dim)archive pull: \(report.downloaded) downloaded\(Terminal.reset)")
            }

            let syncState = try Receipts.syncState()
            if resetBudget {
                var ledger = ReceiptRetryLedger.load(from: syncState)
                ledger.reset()
                ledger.save(to: syncState)
                print("\(Terminal.dim)retry budget cleared\(Terminal.reset)")
            }

            let pipeline = ReceiptPipeline(
                graph: MicrosoftGraphMailClient(config: mailbox),
                driveFolder: config.receipts?.onedrive?.folderPath,
                parser: ReceiptParser(apiKey: config.anthropic.apiKey),
                store: store,
                syncState: syncState,
                zoho: zoho
            )

            print("\n\(Terminal.bold)Retry pass\(all ? " (all pending)" : "")\(Terminal.reset)")
            let summary = try await pipeline.retryPending(policy: all ? .exhaustive : .standard)
            Receipts.printSummary(summary, scanned: "receipt(s)")

            if let engine = await store.syncEngine {
                let report = try await engine.push()
                print("\n\(Terminal.dim)archive push: \(report.uploaded) uploaded\(Terminal.reset)")
            }
        }
    }

    static func printSummary(_ summary: ReceiptPipeline.SyncSummary, scanned: String) {
        for line in summary.lines {
            print("  \(line)")
        }
        print("  \(Terminal.dim)\(summary.messagesSeen) \(scanned) scanned, \(summary.movedMessages) filed\(Terminal.reset)")
        var line = "  \(Terminal.brightGreen)\(summary.matched) matched\(Terminal.reset)"
            + " · \(Terminal.brightYellow)\(summary.ambiguous) ambiguous\(Terminal.reset)"
            + " · \(summary.pending) pending · \(summary.newReceipts) new receipt(s)"
        if summary.deferredRetries > 0 {
            line += " · \(Terminal.dim)\(summary.deferredRetries) held back\(Terminal.reset)"
        }
        if summary.errors > 0 {
            line += " · \(Terminal.brightRed)\(summary.errors) error(s)\(Terminal.reset)"
        }
        print(line)
    }

    // MARK: - List

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List archived receipts and their match status"
        )

        @Option(name: .long, help: "Filter by status: pending | ambiguous | matched | skipped")
        var status: String?

        func run() async throws {
            let store = try Receipts.store(for: ConfigLoader.load())
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
            let store = try Receipts.store(for: config)

            guard let record = await store.record(idPrefix: id) else {
                throw ValidationError("No unique receipt matches ID prefix \"\(id)\" — check `receipts list`.")
            }

            // Validate the expense exists before uploading.
            let detail = try await zoho.fetchExpense(expenseId: expense)

            // Route through the pipeline so the email is also filed under
            // Bookkeeper/Matched in the mailbox it came from.
            let mailboxConfig = config.receipts?.mailboxes.first { $0.address == record.source.mailbox }
                ?? config.receipts?.mailboxes.first
            guard let mailboxConfig else {
                throw ValidationError("No receipt mailboxes configured.")
            }
            let pipeline = ReceiptPipeline(
                graph: MicrosoftGraphMailClient(config: mailboxConfig),
                driveFolder: config.receipts?.onedrive?.folderPath,
                parser: ReceiptParser(apiKey: config.anthropic.apiKey),
                store: store,
                syncState: try Receipts.syncState(),
                zoho: zoho
            )
            try await pipeline.attach(record: record, expenseId: expense)
            if let engine = await store.syncEngine {
                _ = try await engine.push()
            }

            let amount = TaxReadinessReportFormatter.money(detail.total ?? detail.amount ?? 0)
            print(
                "\(Terminal.brightGreen)✓\(Terminal.reset) Attached \(record.parsed?.vendor ?? record.id)"
                    + " to \(detail.vendorName ?? "expense") (\(detail.date ?? "")) \(amount)"
            )
        }
    }
}
