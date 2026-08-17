import Foundation
import ZohoBooksClient

/// One sync of one mailbox: pull new receipt emails from the Inbox, parse,
/// archive, match against Zoho expenses, attach confident matches, retry
/// earlier unmatched receipts, and file each processed email into a state
/// folder — the Inbox is purely the to-process queue, and on the happy path
/// it ends up empty. Emails are only ever moved, never deleted.
public actor ReceiptPipeline {
    /// Mailbox folders that mirror receipt state (children of `folderRoot`).
    public enum MailFolder: String, CaseIterable, Sendable {
        case matched = "Matched"
        case pending = "Pending"
        case needsReview = "Needs Review"
        case notAReceipt = "Not a Receipt"
    }

    public static let folderRoot = "Bookkeeper"

    public struct SyncSummary: Sendable {
        public var messagesSeen = 0
        public var newReceipts = 0
        public var matched = 0
        public var ambiguous = 0
        public var pending = 0
        public var retriedMatches = 0
        public var movedMessages = 0
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

        let messages = try await graph.fetchInboxMessages(since: windowStart)
        summary.messagesSeen = messages.count
        let known = await store.knownMessageIds()

        for message in messages {
            if known.contains(message.id) || (message.internetMessageId.map { known.contains($0) } ?? false) {
                // Already ingested but still in the Inbox (processed before
                // folder-filing existed): file it by its current status.
                try await fileAlreadyIngested(message: message, dryRun: dryRun, summary: &summary)
                continue
            }

            if let adopted = await store.adoptableRecord(
                mailbox: mailbox, subject: message.subject, receivedAt: message.receivedAt
            ) {
                // Same email, drifted Graph ID: update identifiers, then file it.
                var record = adopted
                record.source.messageId = message.id
                record.source.internetMessageId = message.internetMessageId
                if !dryRun {
                    try await store.update(record)
                }
                try await fileMessage(id: message.id, into: folder(for: record.status), dryRun: dryRun, summary: &summary)
                continue
            }

            let outcome = try await ingest(message: message, dryRun: dryRun, summary: &summary)
            summary.newReceipts += outcome.receiptsCreated
            try await fileMessage(id: message.id, into: outcome.folder, dryRun: dryRun, summary: &summary)
        }

        // Hold & retry: previously unmatched receipts get another look now that
        // new expenses may exist in Zoho. Successful matches promote the email.
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

    /// Attach a receipt to a specific expense (manual resolution of
    /// ambiguous/pending receipts), then file its email under Matched.
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

        try await moveEmailIfPossible(for: updated, into: .matched)
    }

    // MARK: - Mailbox filing

    func folder(for status: ReceiptStatus) -> MailFolder {
        switch status {
        case .matched: return .matched
        case .pending: return .pending
        case .ambiguous: return .needsReview
        case .skipped: return .notAReceipt
        }
    }

    /// The folder for a whole email that produced several receipts: the least
    /// finished receipt decides (review > pending > matched).
    static func aggregateFolder(for statuses: [ReceiptStatus]) -> MailFolder {
        if statuses.contains(.ambiguous) { return .needsReview }
        if statuses.contains(.pending) { return .pending }
        if statuses.contains(.matched) { return .matched }
        return .notAReceipt
    }

    private func fileMessage(
        id: String,
        into folder: MailFolder,
        dryRun: Bool,
        summary: inout SyncSummary
    ) async throws {
        if dryRun {
            summary.lines.append("would move → \(Self.folderRoot)/\(folder.rawValue)")
            return
        }
        let folderId = try await graph.ensureFolder(parent: Self.folderRoot, child: folder.rawValue)
        try await graph.moveMessage(id: id, toFolderId: folderId)
        summary.movedMessages += 1
    }

    private func fileAlreadyIngested(
        message: GraphMailClient.MailMessage,
        dryRun: Bool,
        summary: inout SyncSummary
    ) async throws {
        let records = await store.allRecords().filter {
            $0.source.messageId == message.id || ($0.source.internetMessageId != nil && $0.source.internetMessageId == message.internetMessageId)
        }
        guard !records.isEmpty else { return }
        let target = Self.aggregateFolder(for: records.map(\.status))
        try await fileMessage(id: message.id, into: target, dryRun: dryRun, summary: &summary)
    }

    /// Move the email associated with a record, when we still know where it is.
    /// Mailbox trouble here must never fail the bookkeeping operation itself.
    private func moveEmailIfPossible(for record: ReceiptRecord, into folder: MailFolder) async throws {
        guard record.source.kind == "email",
              record.source.mailbox == graph.config.address,
              let messageId = record.source.messageId else { return }
        do {
            let folderId = try await graph.ensureFolder(parent: Self.folderRoot, child: folder.rawValue)
            try await graph.moveMessage(id: messageId, toFolderId: folderId)
        } catch {
            logger.warning("Receipt \(record.id.prefix(8)): couldn't move email to \(folder.rawValue): \(error.localizedDescription)")
        }
    }

    // MARK: - Ingest

    private struct IngestOutcome {
        var receiptsCreated = 0
        var statuses: [ReceiptStatus] = []
        var folder: MailFolder {
            ReceiptPipeline.aggregateFolder(for: statuses)
        }
    }

    private func ingest(
        message: GraphMailClient.MailMessage,
        dryRun: Bool,
        summary: inout SyncSummary
    ) async throws -> IngestOutcome {
        let source = ReceiptRecord.Source(
            kind: "email",
            mailbox: graph.config.address,
            messageId: message.id,
            internetMessageId: message.internetMessageId,
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
                return IngestOutcome()
            }
        }

        var outcome = IngestOutcome()

        if dryRun {
            for payload in payloads {
                summary.lines.append("would ingest: \(message.subject) [\(payload.name)]")
            }
            return outcome
        }

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
            outcome.receiptsCreated += 1

            let matchOutcome = try await matchAgainstZoho(parsed)
            try await apply(outcome: matchOutcome, to: &record, dryRun: dryRun, moveEmail: false, summary: &summary)
            outcome.statuses.append(record.status)
        }
        return outcome
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
        // Retried receipts left the Inbox already — promote their email too.
        try await apply(outcome: outcome, to: &mutable, dryRun: dryRun, moveEmail: true, summary: &summary)
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
        moveEmail: Bool,
        summary: inout SyncSummary
    ) async throws {
        let label = "\(record.parsed?.vendor ?? "?") \(record.parsed?.total.map { String(format: "$%.2f", $0) } ?? "?")"

        switch outcome {
        case .confident(let expense):
            guard let expenseId = expense.expenseId else {
                record.status = .pending
                summary.pending += 1
                return
            }
            if !dryRun {
                if moveEmail {
                    try await attach(record: record, expenseId: expenseId)
                } else {
                    // Email filing is handled by the caller (aggregate move).
                    let fileData = try await store.fileData(for: record)
                    let filename = (record.relativePath as NSString).lastPathComponent
                    try await zoho.uploadExpenseAttachment(expenseId: expenseId, fileData: fileData, filename: filename)
                    record.status = .matched
                    record.matchedExpenseId = expenseId
                    record.attachedToZoho = true
                    try await store.update(record)
                }
            }
            record.status = .matched
            summary.matched += 1
            summary.lines.append("matched: \(label) → \(expense.vendorName ?? "expense") \(expense.date ?? "")")

        case .ambiguous(let expenses):
            record.status = .ambiguous
            record.candidateExpenseIds = expenses.compactMap(\.expenseId)
            if !dryRun {
                try await store.update(record)
                if moveEmail {
                    try await moveEmailIfPossible(for: record, into: .needsReview)
                }
            }
            summary.ambiguous += 1
            summary.lines.append("ambiguous: \(label) — \(expenses.count) candidates (receipts attach --id \(record.id.prefix(8)))")

        case .none:
            record.status = .pending
            summary.pending += 1
            summary.lines.append("pending: \(label) — no matching expense yet")
        }
    }
}
