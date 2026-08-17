import Foundation
import ZohoBooksClient

/// One sync of one mailbox: pull new receipt emails, parse, archive, match
/// against Zoho expenses, attach confident matches, and retry earlier
/// unmatched receipts (hold & retry — nothing is written to Zoho unless a
/// real expense exists to attach to).
public actor ReceiptPipeline {
    public struct SyncSummary: Sendable {
        public var messagesSeen = 0
        public var newReceipts = 0
        public var matched = 0
        public var ambiguous = 0
        public var pending = 0
        public var retriedMatches = 0
        public var lines: [String] = []
    }

    private let graph: GraphMailClient
    private let parser: ReceiptParser
    private let store: ReceiptStore
    private let zoho: ZohoBooksClient<ZohoOAuth>
    private let matcher: ReceiptMatcher

    /// Attachments smaller than this are almost always logos/signatures.
    private let minimumImageBytes = 20_000

    public init(
        graph: GraphMailClient,
        parser: ReceiptParser,
        store: ReceiptStore,
        zoho: ZohoBooksClient<ZohoOAuth>,
        matcher: ReceiptMatcher = ReceiptMatcher()
    ) {
        self.graph = graph
        self.parser = parser
        self.store = store
        self.zoho = zoho
        self.matcher = matcher
    }

    public func sync(dryRun: Bool = false, since: Date? = nil) async throws -> SyncSummary {
        var summary = SyncSummary()
        let mailbox = graph.config.address

        // Overlap the window slightly so boundary messages can't be missed;
        // dedupe below handles the overlap.
        let lastSync = await store.lastSync(mailbox: mailbox)
        let windowStart = since ?? lastSync?.addingTimeInterval(-24 * 3600)

        let messages = try await graph.fetchMessages(since: windowStart)
        summary.messagesSeen = messages.count
        let known = await store.knownMessageIds()

        for message in messages where !known.contains(message.id) {
            let ingested = try await ingest(message: message, dryRun: dryRun, summary: &summary)
            summary.newReceipts += ingested
        }

        // Hold & retry: previously unmatched receipts get another look now
        // that new expenses may exist in Zoho.
        for record in await store.allRecords() where record.status == .pending {
            if try await rematch(record, dryRun: dryRun, summary: &summary) {
                summary.retriedMatches += 1
            }
        }

        if !dryRun {
            await store.setLastSync(mailbox: mailbox, date: Date())
        }
        return summary
    }

    /// Attach a receipt to a specific expense (manual resolution of ambiguous/pending).
    public func attach(record: ReceiptRecord, expenseId: String) async throws {
        let fileData = try await store.fileData(for: record)
        let filename = (record.relativePath as NSString).lastPathComponent
        try await zoho.uploadExpenseAttachment(expenseId: expenseId, fileData: fileData, filename: filename)

        var updated = record
        updated.status = .matched
        updated.matchedExpenseId = expenseId
        updated.attachedToZoho = true
        updated.candidateExpenseIds = []
        try await store.update(updated)
    }

    // MARK: - Ingest

    /// Returns the number of receipts created from this message.
    private func ingest(
        message: GraphMailClient.MailMessage,
        dryRun: Bool,
        summary: inout SyncSummary
    ) async throws -> Int {
        let source = ReceiptRecord.Source(
            kind: "email",
            mailbox: graph.config.address,
            messageId: message.id,
            subject: message.subject,
            from: message.from,
            receivedAt: message.receivedAt
        )

        var payloads: [(data: Data, contentType: String, ext: String, name: String)] = []

        if message.hasAttachments {
            for attachment in try await graph.fetchAttachments(messageId: message.id) {
                let type = attachment.contentType.lowercased()
                if type.contains("pdf") {
                    payloads.append((attachment.data, attachment.contentType, "pdf", attachment.name))
                } else if ReceiptParser.imageMediaType(for: type) != nil, attachment.data.count >= minimumImageBytes {
                    let ext = (attachment.name as NSString).pathExtension.lowercased()
                    payloads.append((attachment.data, attachment.contentType, ext.isEmpty ? "jpg" : ext, attachment.name))
                }
            }
        }

        // No usable attachments: the email body *is* the receipt.
        if payloads.isEmpty {
            if let html = try await graph.fetchBodyHTML(messageId: message.id), !html.isEmpty {
                payloads.append((Data(html.utf8), "text/html", "html", "body.html"))
            } else {
                summary.lines.append("skip: \(message.subject) — no attachments or body")
                return 0
            }
        }

        if dryRun {
            for payload in payloads {
                summary.lines.append("would ingest: \(message.subject) [\(payload.name)]")
            }
            return 0
        }

        var created = 0
        for payload in payloads {
            let parsed = try await parser.parse(
                fileData: payload.data,
                contentType: payload.contentType,
                filename: payload.name
            )

            guard parsed.confidence > 0 else {
                summary.lines.append("skip: \(message.subject) [\(payload.name)] — not a receipt")
                continue
            }

            var record = try await store.ingest(
                fileData: payload.data,
                fileExtension: payload.ext,
                source: source,
                parsed: parsed
            )
            created += 1

            let outcome = try await matchAgainstZoho(parsed)
            try await apply(outcome: outcome, to: &record, dryRun: dryRun, summary: &summary)
        }
        return created
    }

    // MARK: - Matching

    private func rematch(
        _ record: ReceiptRecord,
        dryRun: Bool,
        summary: inout SyncSummary
    ) async throws -> Bool {
        guard let parsed = record.parsed else { return false }
        let outcome = try await matchAgainstZoho(parsed)
        if case .none = outcome { return false }
        var mutable = record
        try await apply(outcome: outcome, to: &mutable, dryRun: dryRun, summary: &summary)
        return true
    }

    private func matchAgainstZoho(_ parsed: ParsedReceipt) async throws -> ReceiptMatchOutcome {
        // Candidate window around the receipt date (or a recent window when undated).
        let anchor = parsed.date.flatMap { GapDetector.parseDate($0) } ?? Date()
        let window: TimeInterval = 14 * 24 * 3600
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")!
        formatter.dateFormat = "yyyy-MM-dd"

        let candidates = try await zoho.fetchExpenses(
            dateStart: formatter.string(from: anchor.addingTimeInterval(-window)),
            dateEnd: formatter.string(from: anchor.addingTimeInterval(window))
        )
        return matcher.match(receipt: parsed, candidates: candidates)
    }

    private func apply(
        outcome: ReceiptMatchOutcome,
        to record: inout ReceiptRecord,
        dryRun: Bool,
        summary: inout SyncSummary
    ) async throws {
        let label = "\(record.parsed?.vendor ?? "?") \(record.parsed?.total.map { String(format: "$%.2f", $0) } ?? "?")"

        switch outcome {
        case .confident(let expense):
            guard let expenseId = expense.expenseId else {
                summary.pending += 1
                return
            }
            if !dryRun {
                try await attach(record: record, expenseId: expenseId)
                record.status = .matched
            }
            summary.matched += 1
            summary.lines.append("matched: \(label) → \(expense.vendorName ?? "expense") \(expense.date ?? "")")

        case .ambiguous(let expenses):
            record.status = .ambiguous
            record.candidateExpenseIds = expenses.compactMap(\.expenseId)
            if !dryRun {
                try await store.update(record)
            }
            summary.ambiguous += 1
            summary.lines.append("ambiguous: \(label) — \(expenses.count) candidates (receipts attach --id \(record.id.prefix(8)))")

        case .none:
            summary.pending += 1
            summary.lines.append("pending: \(label) — no matching expense yet")
        }
    }
}
