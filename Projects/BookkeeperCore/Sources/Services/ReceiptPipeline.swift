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
        public var errors = 0
        public var lines: [String] = []

        public mutating func merge(_ other: SyncSummary) {
            messagesSeen += other.messagesSeen
            newReceipts += other.newReceipts
            matched += other.matched
            ambiguous += other.ambiguous
            pending += other.pending
            retriedMatches += other.retriedMatches
            movedMessages += other.movedMessages
            errors += other.errors
            lines += other.lines
        }
    }

    /// Nil when the pipeline only processes local files (iOS share extension) —
    /// mailbox operations are skipped in that mode.
    private let graph: GraphMailClient?
    /// OneDrive folder path swept as a second receipts inbox (nil = disabled).
    private let driveFolder: String?
    private let parser: ReceiptParser
    private let store: ReceiptStore
    private let zoho: ZohoBooksClient<ZohoOAuth>
    private let matcher: ReceiptMatcher

    /// Attachments smaller than this are almost always logos/signatures.
    private let minimumImageBytes = 20_000

    public init(
        graph: GraphMailClient? = nil,
        driveFolder: String? = nil,
        parser: ReceiptParser,
        store: ReceiptStore,
        zoho: ZohoBooksClient<ZohoOAuth>,
        matcher: ReceiptMatcher = ReceiptMatcher()
    ) {
        self.graph = graph
        self.driveFolder = driveFolder
        self.parser = parser
        self.store = store
        self.zoho = zoho
        self.matcher = matcher
    }

    /// Ingest a locally provided receipt file (share extension, camera roll):
    /// parse → archive → match → attach when confident. Returns nil (with a
    /// human-readable line) when the file isn't a receipt.
    public func processLocalFile(
        data: Data,
        contentType: String,
        filename: String,
        source: ReceiptRecord.Source
    ) async throws -> (record: ReceiptRecord?, line: String) {
        let parsed = try await parser.parse(fileData: data, contentType: contentType, filename: filename)
        guard parsed.confidence > 0 else {
            return (nil, "skip: \(filename) — not a receipt")
        }

        let ext = (filename as NSString).pathExtension.lowercased()
        var record = try await store.ingest(
            fileData: data,
            fileExtension: ext.isEmpty ? (contentType.contains("pdf") ? "pdf" : "jpg") : ext,
            source: source,
            parsed: parsed
        )

        var summary = SyncSummary()
        let outcome = try await matchAgainstZoho(parsed)
        try await apply(outcome: outcome, to: &record, dryRun: false, moveEmail: false, summary: &summary)
        return (record, summary.lines.last ?? "")
    }

    /// Retry matching for all pending receipts (no mailbox needed; emails and
    /// drive files are promoted when a graph client is available).
    public func retryPending() async throws -> SyncSummary {
        await retryPendingInternal(dryRun: false)
    }

    private func retryPendingInternal(dryRun: Bool) async -> SyncSummary {
        var summary = SyncSummary()
        for record in await store.allRecords() where record.status == .pending {
            do {
                if try await rematch(record, dryRun: dryRun, summary: &summary) {
                    summary.retriedMatches += 1
                }
            } catch {
                summary.errors += 1
                summary.lines.append("error retrying \(record.parsed?.vendor ?? record.id): \(error.localizedDescription)")
            }
        }
        return summary
    }

    /// - Parameter runRetryPass: set false when the caller orchestrates several
    ///   syncs (mail + drive) and wants a single hold-&-retry pass at the end
    ///   instead of one per sync — the retry pass is the API-heavy part.
    public func sync(dryRun: Bool = false, since: Date? = nil, runRetryPass: Bool = true) async throws -> SyncSummary {
        guard let graph else {
            throw GraphError.notSignedIn(mailbox: "(no mailbox configured for this pipeline)")
        }
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
            // One failing message (bad attachment, Zoho hiccup) must not
            // abort the whole sync — record it and keep going.
            do {
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

                let outcome = try await ingest(message: message, graph: graph, dryRun: dryRun, summary: &summary)
                summary.newReceipts += outcome.receiptsCreated
                try await fileMessage(id: message.id, into: outcome.folder, dryRun: dryRun, summary: &summary)
            } catch {
                summary.errors += 1
                summary.lines.append("error: \(message.subject) — \(error.localizedDescription)")
            }
        }

        // Hold & retry: previously unmatched receipts get another look now that
        // new expenses may exist in Zoho. Successful matches promote the email.
        if runRetryPass {
            let retry = await retryPendingInternal(dryRun: dryRun)
            summary.merge(retry)
        }

        if !dryRun {
            await store.setLastSync(mailbox: mailbox, date: Date())
        }
        return summary
    }

    // MARK: - OneDrive folder sync

    /// One sweep of the OneDrive receipts folder: every receipt-type file
    /// outside the state subfolders is downloaded, parsed, archived, matched,
    /// and then moved into a state subfolder (its original subpath preserved,
    /// so "2025-Q2/x.pdf" files under "Matched/2025-Q2/x.pdf"). Non-receipt
    /// file types (scripts, CSVs, zips) are never touched. Files are only
    /// ever moved, never deleted — on the happy path the folder root and its
    /// organizational subfolders end up empty.
    public func syncDrive(dryRun: Bool = false, runRetryPass: Bool = true) async throws -> SyncSummary {
        guard let graph, let driveFolder else {
            throw GraphError.notSignedIn(mailbox: "(no OneDrive folder configured for this pipeline)")
        }
        var summary = SyncSummary()

        let stateNames = Set(MailFolder.allCases.map(\.rawValue))
        let items = try await graph.listDriveFiles(
            folderPath: driveFolder,
            excludingTopLevelFolders: stateNames
        )
        summary.messagesSeen = items.count
        let known = await store.knownMessageIds()

        for item in items {
            do {
                guard Self.isReceiptFile(item.name) else { continue }

                if known.contains(item.id) {
                    // Ingested before but still in place (e.g. a move failed):
                    // file it by its current status.
                    if let record = await store.allRecords().first(where: { $0.source.messageId == item.id }) {
                        try await fileDriveItem(item, into: folder(for: record.status), dryRun: dryRun, summary: &summary)
                    }
                    continue
                }

                if dryRun {
                    summary.lines.append("would ingest: \(item.relativePath)")
                    continue
                }

                let data = try await graph.downloadDriveItem(id: item.id)
                let ext = (item.name as NSString).pathExtension.lowercased()
                let parsed = try await parser.parse(
                    fileData: data,
                    contentType: Self.contentType(forExtension: ext),
                    filename: item.name
                )

                guard parsed.confidence > 0 else {
                    summary.lines.append("skip: \(item.relativePath) — not a receipt")
                    try await fileDriveItem(item, into: .notAReceipt, dryRun: dryRun, summary: &summary)
                    continue
                }

                var record = try await store.ingest(
                    fileData: data,
                    fileExtension: ext,
                    source: ReceiptRecord.Source(
                        kind: "onedrive",
                        messageId: item.id,
                        subject: item.name,
                        receivedAt: item.lastModified,
                        path: item.relativePath
                    ),
                    parsed: parsed
                )
                summary.newReceipts += 1

                let outcome = try await matchAgainstZoho(parsed)
                try await apply(outcome: outcome, to: &record, dryRun: dryRun, moveEmail: false, summary: &summary)
                try await fileDriveItem(item, into: folder(for: record.status), dryRun: dryRun, summary: &summary)
            } catch {
                summary.errors += 1
                summary.lines.append("error: \(item.relativePath) — \(error.localizedDescription)")
            }
        }

        // Hold & retry, same as the mailbox sync. Promoted receipts get their
        // source (email or drive file) refiled too.
        if runRetryPass {
            let retry = await retryPendingInternal(dryRun: dryRun)
            summary.merge(retry)
        }
        return summary
    }

    /// File types the pipeline processes from the drive folder. Everything
    /// else (scripts, CSVs, zips, HTML tooling output) stays where it is.
    static func isReceiptFile(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["pdf", "png", "jpg", "jpeg", "gif", "webp"].contains(ext)
    }

    static func contentType(forExtension ext: String) -> String {
        switch ext {
        case "pdf": return "application/pdf"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }

    /// State destination for a drive file, preserving its original subpath:
    /// ("Matched", "2025-Q2/x.pdf") → "Matched/2025-Q2".
    static func driveStateSubpath(state: MailFolder, originalRelativePath: String) -> String {
        let subdir = (originalRelativePath as NSString).deletingLastPathComponent
        return subdir.isEmpty ? state.rawValue : "\(state.rawValue)/\(subdir)"
    }

    private func fileDriveItem(
        _ item: GraphMailClient.DriveItem,
        into folder: MailFolder,
        dryRun: Bool,
        summary: inout SyncSummary
    ) async throws {
        guard let graph, let driveFolder else { return }
        let destination = Self.driveStateSubpath(state: folder, originalRelativePath: item.relativePath)
        if dryRun {
            summary.lines.append("would move → \(destination)/\(item.name)")
            return
        }
        let folderId = try await graph.ensureDriveFolder(subPath: destination, under: driveFolder)
        try await graph.moveDriveItem(id: item.id, toFolderId: folderId)
        summary.movedMessages += 1
    }

    /// Attach a receipt to a specific expense (manual resolution of
    /// ambiguous/pending receipts), then file its email under Matched.
    public func attach(record: ReceiptRecord, expenseId: String) async throws {
        let payload = try await attachmentPayload(for: record)
        try await zoho.uploadExpenseAttachment(expenseId: expenseId, fileData: payload.data, filename: payload.filename)

        var updated = record
        updated.status = .matched
        updated.matchedExpenseId = expenseId
        updated.attachedToZoho = true
        updated.candidateExpenseIds = []
        try await store.update(updated)

        try await moveSourceIfPossible(for: updated, into: .matched)
    }

    /// The bytes + filename to send to Zoho. Zoho rejects .html attachments,
    /// so HTML-bodied receipts are rendered to a text PDF for upload; the
    /// original .html stays untouched in the archive.
    private func attachmentPayload(for record: ReceiptRecord) async throws -> (data: Data, filename: String) {
        let fileData = try await store.fileData(for: record)
        let filename = (record.relativePath as NSString).lastPathComponent

        if filename.lowercased().hasSuffix(".html") {
            let html = String(data: fileData, encoding: .utf8) ?? ""
            let text = ReceiptParser.stripHTML(html)
            let title = [record.parsed?.vendor, record.parsed?.date, record.source.subject]
                .compactMap { $0 }
                .joined(separator: " — ")
            if let pdf = TextPDFRenderer.pdfData(text: text, title: title) {
                return (pdf, (filename as NSString).deletingPathExtension + ".pdf")
            }
        }
        return (fileData, filename)
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
        guard let graph else { return }
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

    /// Refile a record's source (email or OneDrive file) when we still know
    /// where it is. Graph trouble here must never fail the bookkeeping
    /// operation itself.
    private func moveSourceIfPossible(for record: ReceiptRecord, into folder: MailFolder) async throws {
        guard let graph else { return }
        do {
            switch record.source.kind {
            case "email":
                guard record.source.mailbox == graph.config.address,
                      let messageId = record.source.messageId else { return }
                let folderId = try await graph.ensureFolder(parent: Self.folderRoot, child: folder.rawValue)
                try await graph.moveMessage(id: messageId, toFolderId: folderId)

            case "onedrive":
                guard let driveFolder,
                      let itemId = record.source.messageId,
                      let originalPath = record.source.path else { return }
                let destination = Self.driveStateSubpath(state: folder, originalRelativePath: originalPath)
                let folderId = try await graph.ensureDriveFolder(subPath: destination, under: driveFolder)
                try await graph.moveDriveItem(id: itemId, toFolderId: folderId)

            default:
                return
            }
        } catch {
            logger.warning("Receipt \(record.id.prefix(8)): couldn't refile source to \(folder.rawValue): \(error.localizedDescription)")
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
        graph: GraphMailClient,
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
                    let payload = try await attachmentPayload(for: record)
                    try await zoho.uploadExpenseAttachment(expenseId: expenseId, fileData: payload.data, filename: payload.filename)
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
                    try await moveSourceIfPossible(for: record, into: .needsReview)
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
