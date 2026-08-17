import Foundation
import Testing
import ZohoBooksClient
@testable import BookkeeperCore

private func expense(id: String, date: String, amount: Double, vendor: String? = nil) -> ZBExpense {
    ZBExpense(expenseId: id, vendorName: vendor, date: date, amount: amount, total: amount)
}

@Suite("ReceiptMatcher")
struct ReceiptMatcherTests {
    private let matcher = ReceiptMatcher()

    private func receipt(total: Double?, date: String? = "2026-08-10", vendor: String? = "Amazon") -> ParsedReceipt {
        ParsedReceipt(vendor: vendor, date: date, total: total, confidence: 90)
    }

    @Test("Single exact-amount match within the date window is confident")
    func exactMatch() {
        let outcome = matcher.match(
            receipt: receipt(total: 42.50),
            candidates: [
                expense(id: "e1", date: "2026-08-11", amount: 42.50),
                expense(id: "e2", date: "2026-08-11", amount: 99.00),
            ]
        )
        guard case .confident(let matched) = outcome else {
            Issue.record("Expected confident, got \(outcome)")
            return
        }
        #expect(matched.expenseId == "e1")
    }

    @Test("Outside the date window is not a match")
    func dateWindow() {
        let outcome = matcher.match(
            receipt: receipt(total: 42.50),
            candidates: [expense(id: "e1", date: "2026-08-30", amount: 42.50)]
        )
        guard case .none = outcome else {
            Issue.record("Expected none, got \(outcome)")
            return
        }
    }

    @Test("Two exact-amount candidates: unique vendor match wins, else ambiguous")
    func vendorTieBreak() {
        let candidates = [
            expense(id: "e1", date: "2026-08-10", amount: 42.50, vendor: "Amazon.com"),
            expense(id: "e2", date: "2026-08-11", amount: 42.50, vendor: "Staples"),
        ]
        let winner = matcher.match(receipt: receipt(total: 42.50, vendor: "Amazon"), candidates: candidates)
        guard case .confident(let matched) = winner, matched.expenseId == "e1" else {
            Issue.record("Expected confident e1, got \(winner)")
            return
        }

        let tie = matcher.match(receipt: receipt(total: 42.50, vendor: "Zulily"), candidates: candidates)
        guard case .ambiguous(let options) = tie, options.count == 2 else {
            Issue.record("Expected 2-way ambiguous, got \(tie)")
            return
        }
    }

    @Test("Tolerance-only match needs a vendor match to be confident")
    func toleranceNeedsVendor() {
        // 1.5% off — inside the 2% tolerance, not exact.
        let candidates = [expense(id: "e1", date: "2026-08-10", amount: 101.50, vendor: "Acme Hosting")]

        let withVendor = matcher.match(receipt: receipt(total: 100.00, vendor: "Acme"), candidates: candidates)
        guard case .confident = withVendor else {
            Issue.record("Expected confident, got \(withVendor)")
            return
        }

        let withoutVendor = matcher.match(receipt: receipt(total: 100.00, vendor: "Mystery"), candidates: candidates)
        guard case .ambiguous(let options) = withoutVendor, options.count == 1 else {
            Issue.record("Expected 1-way ambiguous, got \(withoutVendor)")
            return
        }
    }

    @Test("Undated receipts only match on exact amount")
    func undatedReceipt() {
        let exact = matcher.match(
            receipt: receipt(total: 42.50, date: nil),
            candidates: [expense(id: "e1", date: "2026-05-01", amount: 42.50)]
        )
        guard case .confident = exact else {
            Issue.record("Expected confident, got \(exact)")
            return
        }

        let fuzzy = matcher.match(
            receipt: receipt(total: 100.00, date: nil),
            candidates: [expense(id: "e1", date: "2026-05-01", amount: 101.50, vendor: "Acme")]
        )
        guard case .none = fuzzy else {
            Issue.record("Expected none, got \(fuzzy)")
            return
        }
    }

    @Test("Missing or zero totals never match")
    func missingTotal() {
        for total in [nil, 0.0] as [Double?] {
            let outcome = matcher.match(
                receipt: receipt(total: total),
                candidates: [expense(id: "e1", date: "2026-08-10", amount: 0)]
            )
            guard case .none = outcome else {
                Issue.record("Expected none for total \(String(describing: total))")
                return
            }
        }
    }

    @Test("Vendor similarity normalizes punctuation and case")
    func vendorNormalization() {
        #expect(ReceiptMatcher.vendorsSimilar("AMAZON.COM*1X2Y", "Amazon.com 1x2y"))
        #expect(ReceiptMatcher.vendorsSimilar("Acme", "ACME Hosting Inc."))
        #expect(!ReceiptMatcher.vendorsSimilar("Acme", "Staples"))
        #expect(!ReceiptMatcher.vendorsSimilar(nil, "Staples"))
    }
}

@Suite("ReceiptParser response handling")
struct ReceiptParserTests {

    @Test("Well-formed extraction JSON parses")
    func parseGood() {
        let parsed = ReceiptParser.parseResponse("""
        {"vendor": "Adobe", "date": "2026-08-01", "total": 59.99, "currency": "USD", \
        "card_last4": "4321", "confidence": 95, "notes": null}
        """)
        #expect(parsed.vendor == "Adobe")
        #expect(parsed.total == 59.99)
        #expect(parsed.cardLast4 == "4321")
        #expect(parsed.confidence == 95)
    }

    @Test("Garbage degrades to zero confidence")
    func parseGarbage() {
        #expect(ReceiptParser.parseResponse("sorry, can't help").confidence == 0)
    }

    @Test("HTML stripping keeps text, drops tags/styles")
    func htmlStrip() {
        let html = """
        <html><head><style>body{color:red}</style></head>
        <body><h1>Receipt</h1><p>Total: <b>$42.50</b>&nbsp;USD</p>
        <script>track()</script></body></html>
        """
        let text = ReceiptParser.stripHTML(html)
        #expect(text.contains("Total: $42.50 USD"))
        #expect(!text.contains("<"))
        #expect(!text.contains("track()"))
        #expect(!text.contains("color:red"))
    }

    @Test("Content routing: pdf → document, jpeg → image, html → text")
    func contentRouting() throws {
        let pdf = try ReceiptParser.messageContent(fileData: Data("x".utf8), contentType: "application/pdf", filename: "r.pdf")
        guard case .list(let pdfItems) = pdf, case .document = pdfItems.first else {
            Issue.record("Expected document block")
            return
        }

        let image = try ReceiptParser.messageContent(fileData: Data("x".utf8), contentType: "image/jpeg", filename: "r.jpg")
        guard case .list(let imageItems) = image, case .image = imageItems.first else {
            Issue.record("Expected image block")
            return
        }

        let html = try ReceiptParser.messageContent(fileData: Data("<b>hi</b>".utf8), contentType: "text/html", filename: "b.html")
        guard case .text(let text) = html else {
            Issue.record("Expected text content")
            return
        }
        #expect(text.contains("hi"))
    }
}

@Suite("ReceiptStore")
struct ReceiptStoreTests {

    private func makeStore() throws -> (ReceiptStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("receipt-store-tests-\(UUID().uuidString)")
        return (try ReceiptStore(root: dir), dir)
    }

    @Test("Ingest writes file + sidecar; records round-trip")
    func ingestRoundTrip() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = try await store.ingest(
            fileData: Data("pdf-bytes".utf8),
            fileExtension: "pdf",
            source: .init(kind: "email", mailbox: "billing@x.com", messageId: "m1", subject: "Your Amazon receipt"),
            parsed: ParsedReceipt(vendor: "Amazon", date: "2026-08-12", total: 42.5, confidence: 90)
        )

        #expect(record.relativePath.hasPrefix("2026/2026-08-12-amazon-"))
        #expect(try await store.fileData(for: record) == Data("pdf-bytes".utf8))

        let all = await store.allRecords()
        #expect(all.count == 1)
        #expect(all.first?.parsed?.vendor == "Amazon")
        #expect(await store.knownMessageIds() == ["m1"])
        #expect(await store.record(idPrefix: String(record.id.prefix(8)))?.id == record.id)
    }

    @Test("Status updates persist")
    func statusUpdate() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        var record = try await store.ingest(
            fileData: Data("x".utf8),
            fileExtension: "html",
            source: .init(kind: "email", messageId: "m2"),
            parsed: ParsedReceipt(vendor: "Acme", date: "2026-08-01", total: 10, confidence: 80)
        )
        record.status = .matched
        record.matchedExpenseId = "exp-9"
        record.attachedToZoho = true
        try await store.update(record)

        let reloaded = await store.allRecords().first
        #expect(reloaded?.status == .matched)
        #expect(reloaded?.matchedExpenseId == "exp-9")
        #expect(reloaded?.attachedToZoho == true)
    }

    @Test("Sync state round-trips per mailbox")
    func syncState() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(await store.lastSync(mailbox: "a@x.com") == nil)
        let now = Date()
        await store.setLastSync(mailbox: "a@x.com", date: now)
        let loaded = await store.lastSync(mailbox: "a@x.com")
        #expect(abs((loaded?.timeIntervalSince(now)) ?? 999) < 1)
        #expect(await store.lastSync(mailbox: "b@x.com") == nil)
    }

    @Test("Filename slugs are filesystem-safe")
    func slugs() {
        #expect(ReceiptStore.slug("AMAZON.COM*1X 2Y/3Z") == "amazon-com-1x-2y-3z")
        #expect(ReceiptStore.slug("///") == "receipt")
    }
}

@Suite("Graph tokens")
struct GraphTokenTests {

    @Test("Refresh triggers a minute before expiry")
    func refreshWindow() {
        let now = Date()
        let fresh = GraphTokens(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(3600))
        #expect(!fresh.needsRefresh(now: now))

        let closeToExpiry = GraphTokens(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(30))
        #expect(closeToExpiry.needsRefresh(now: now))

        let expired = GraphTokens(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(-10))
        #expect(expired.needsRefresh(now: now))
    }
}
