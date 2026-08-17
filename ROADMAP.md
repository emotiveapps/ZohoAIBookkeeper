# Tax-Readiness & Audit-Protection Roadmap — ZohoAIBookkeeper

> **Status (Aug 17, 2026):** Phase 0, 1, and 1.5 are **built and verified live** (`audit`/`gaps`/`cogs` commands, app Tax Readiness screen). Phase 2's **email pipeline is built and verified live** against billing@luckyfrog.com (`receipts login|sync|list|attach`): first sync rejected 16 marketing emails and archived 2 real receipts (Bricqer invoice PDF, forwarded Home Depot order), both held pending until their expenses appear in Zoho. Processed emails are filed into mailbox state folders (`Bookkeeper/{Matched, Pending, Needs Review, Not a Receipt}`) — moved, never deleted — so the Inbox stays an empty to-process queue; the full backlog was processed (294 messages → Inbox 0, 277 receipts archived, 127 auto-attached to Zoho expenses). Sync runs automatically every 4h via LaunchAgent (`just install`). The **iOS share extension + app Receipts screen are built** (share a PDF/photo → app-group queue → parse/archive/match in-app, with ambiguous-match resolution). Deliberately skipped: the emotiveapps.com mailbox (unused/empty). Phases 3–4 not started.

## Context

The tool currently does one thing well: categorize uncategorized bank transactions (CLI + the newly rewritten iPhone/iPad app). The owner's larger goal is **filing FY2025 and FY2026 taxes with confidence and surviving a future audit**: every expense captured and categorized, bank-feed outages detected (silent gaps = understated expenses = overpaid tax, or missing income = audit risk), and receipts attached as documentation without paying for a receipt-processing SaaS. Receipts today mostly don't get kept because uploading is a pain. Email receipts live in billing@luckyfrog.com and billing@emotiveapps.com — **Microsoft 365 for Business** (not Gmail), so email ingestion uses the Microsoft Graph API.

User decisions already made:
- Capture paths: **email polling (Microsoft Graph)** + **iOS share extension** (paper receipts on the go).
- Unmatched receipts: **hold & retry** — never write to Zoho until a real expense exists to attach to.
- Build order: **tax audit + gap detection first** (FY2025 extension deadline is Oct 15, 2026), receipts second.

Assumptions (flag if wrong): calendar-year tax years (FY2025 = Jan–Dec 2025); Zoho Books stays the system of record; single-user, personal infrastructure only.

---

## Phase 0 — API groundwork (ZohoBooksClient, sibling repo)

New features hammer endpoints the client handles poorly (see `../ZohoBooksClient/CODE_REVIEW.md`). Prerequisites:

1. **`fetchTransactions(accountId:dateRange:status:)`** — today only `fetchUncategorizedTransactions` exists (`ZohoBooksClient.swift:437`). Gap detection and completeness need *all* statuses (`filter_by=Status.All`, `date_start`/`date_end`). Reuse the existing pagination-loop pattern.
2. **Generic `fetchAllPages` helper** — fixes Z4 (five list endpoints silently truncate at one page); expense/report sweeps will exceed 200 records.
3. **Expense documentation status** — extend `fetchExpenses` to surface `documents`/`has_attachment` so coverage reporting can tell which expenses lack receipts (add fields to `ZBExpense`, add a `has_attachment` filter variant).
4. Opportunistic while in there: Z1 (move OAuth refresh params from URL query to POST body) and Z3 (server-side `contact_name` search) — small, and Phase 2 calls `getOrCreateVendor` often.

## Phase 1 — FY completeness audit + bank-feed gap detection (CLI-first)

**New BookkeeperCore services** (follow the existing actor + protocol-seam pattern, e.g. `VendorHistorySource` in `HistoryMatcher.swift`):

- `GapDetector` (pure logic, fully testable): given all transactions for an account/year, bucket by week; flag (a) zero-activity windows bracketed by normal activity, using each account's own median cadence, (b) feed staleness (days since latest transaction vs. account's cadence), (c) month-over-month count collapses. Output structured findings with severity + human summary.
- `TaxReadinessAuditor`: per year × account — uncategorized count, expenses missing vendor, expenses missing category (mapped to "Uncategorized"), expenses missing documentation (Phase 0 #3), gap findings, totals per category. Produces a `TaxReadinessReport` model.
- Optional Claude pass: one call to `ClaudeService` to write the executive summary ("what to fix before filing") from the structured report — cheap, high-value narrative.

**CLI** (`Projects/CLI/Sources/ZohoBookkeeperCLI.swift`, new subcommands):
- `zoho-bookkeeper audit --year 2025` — full readiness report, exit non-zero if blockers exist (uncategorized > 0, gaps found). `--markdown`/`--csv` export to `~/.zoho-ai-bookkeeper/reports/2025/` for the accountant.
- `zoho-bookkeeper gaps --year 2025 [--account <id>]` — gap findings only, week-by-week sparkline per account in the TUI style.

**App**: a "Tax readiness" card on `HomeView` (per-year blocker counts, tap → report screen). Reuses the same core services via `Workspace`.

## Phase 2 — Receipt capture, matching & attachment (audit-protection centerpiece)

**Ingestion**
- `ReceiptMailPoller` (BookkeeperCore, macOS + iOS): Microsoft Graph REST — device-code OAuth against a self-registered Entra app (`Mail.Read` delegated scope), tokens in `KeychainCredentialsStore`-style storage; polls both billing mailboxes for messages in a designated folder/category ("Receipts" — user forwards anything there), downloads attachments + HTML bodies (rendered to PDF for HTML-only receipts). Runs via `zoho-bookkeeper receipts sync` and from the app.
- **iOS share extension** (new Tuist target in `Projects/App`): share a PDF/image/screenshot from any app → drops into the app's ingest queue via app-group container. In-app camera capture can ride the same queue later.

**Pipeline** (all new BookkeeperCore services, protocol seams for tests)
- `ReceiptParser`: Claude vision/PDF call extracts vendor, date, total, currency, card last-4 → structured `ParsedReceipt` (reuse `ClaudeService`'s JSON-response pattern + the hardened parser).
- `ReceiptMatcher`: candidate Zoho expenses by amount (±$0.01, then ±2% for tips/FX), date window (±5 days), vendor similarity. Confident match → `uploadExpenseAttachment` (already exists in ZohoBooksClient) and record linkage. Ambiguous → review queue. No match → **hold & retry** after every `receipts sync` and after every `clean`/app save session.
- `ReceiptStore`: local filing cabinet `~/.zoho-ai-bookkeeper/receipts/<year>/` — original file + JSON sidecar (parse result, match status, Zoho expense id, message id for dedupe). This is the audit archive even independent of Zoho (IRS retention: keep ≥7 years).

**Review UX**: app gets a "Receipts" section (pending/ambiguous queue, one-tap confirm match); CLI gets `receipts list|match|sync`.

## Phase 1.5 — Inventory & COGS handling (LEGO resale)

Decision (owner + assistant, confirm §471(c) nuance with CPA): inventory purchases are recorded **at purchase time to an Inventory Asset account** (not an expense, not left until sale); the deduction happens via **periodic COGS** (year-end: COGS = beginning inventory + purchases − ending inventory). Receipts for inventory purchases are basis documentation — capture them like any expense receipt.

- **Category sourcing**: `fetchExpenseCategories` (CLI) and `Workspace.refresh` currently filter the chart of accounts to `account_type == "expense"` only — widen to include `cost_of_goods_sold` and stock/`other_current_asset` accounts, visually grouped ("Inventory & COGS") in both pickers so LEGO buys can be routed to Inventory Asset.
- **Prompt guidance**: teach `ClaudeService.buildSystemPrompt` that purchases from LEGO/toy/brick vendors resold as inventory → suggest the Inventory Asset category, not an expense.
- **Year-end COGS helper**: `audit --year` breaks out inventory-account activity (total purchased); a small `zoho-bookkeeper cogs --year 2025 --ending-inventory <value>` computes the COGS adjustment to hand the accountant (no journal-entry write to Zoho in v1 — report only).

## Phase 3 — Audit-readiness reporting

- Documentation coverage per year: % of expenses with receipts, weighted by amount; hit-list of undocumented expenses above a threshold (default $75 — IRS receipt floor — configurable).
- `zoho-bookkeeper export --year 2025`: one bundle per year (CSV of all categorized expenses + receipt files + coverage report) → hand to accountant / keep for audit defense.
- App: coverage ring on the tax-readiness card.

## Phase 4 — Run-a-good-business layer (after the above)

Monthly digest (CLI command now, scheduled later): spend by category vs. trailing average, new vendors, **subscription price-creep** (same vendor, rising recurring amount), **duplicate-charge detection** (same vendor+amount within days), quarterly **estimated-tax reminder** with YTD profit context.

## Recommended additional goals (asked: "what other goals should I have?")

1. **1099-NEC tracking** — flag vendors paid ≥$600/year that look like contractors; year-end you need their W-9s. Cheap to compute from data already fetched.
2. **Income-side completeness** — everything here is expense-focused, but audits start with income. Reconcile Zoho sales/deposits against Stripe/PayPal accounts (both exist in your account list) so unexplained deposits get categorized too.
3. **Zoho data export/backup** — periodic local export of the full books (you're relying on a SaaS to hold 7 years of audit history; `export --year` partially covers this — consider an `export --all`).
4. **Business/personal separation hygiene** — the categorizer already knows "owner contribution"; report on how often personal cards pay business expenses (each is an audit-narrative liability worth minimizing).
5. **Reconciliation against statements** — gap detection catches missing *feeds*; statement reconciliation catches missing *transactions*. **Done (Aug 17, 2026)** for six accounts via `scripts/reconcile_statements.py`: ~100 genuinely missing transactions identified and imported, ~154 duplicate uncategorized lines excluded (reversibly). Also corrected the record: the "feeds died Jan 2026" finding was an artifact of Zoho's API hiding uncategorized lines — feeds were healthy, transactions were just piling up uncategorized since ~Oct 2025. Remaining hole: AMEX Amazon Business 2026 history (card migrated to US Bank; owner calling Amex).

## Critical files

- `../ZohoBooksClient/Sources/ZohoBooksClient/ZohoBooksClient.swift` — Phase 0 additions
- `Projects/BookkeeperCore/Sources/Services/` — new: `GapDetector`, `TaxReadinessAuditor`, `ReceiptParser`, `ReceiptMatcher`, `ReceiptStore`, `ReceiptMailPoller` (reuse: `ClaudeService`, `CacheService` patterns, `KeychainCredentialsStore`, `TransactionCategorizer`)
- `Projects/CLI/Sources/ZohoBookkeeperCLI.swift` — new subcommands (`audit`, `gaps`, `receipts`, `export`)
- `Projects/App/` — tax-readiness card (`HomeView.swift`), receipts review section, new share-extension target (`Projects/App/Project.swift` + `Project+Templates.swift` for the extension template)
- `Projects/BookkeeperCore/Tests/` — GapDetector and ReceiptMatcher are pure logic: test-first (synthetic transaction timelines with known gaps; synthetic receipt/expense pairs)

## Verification

- **Phase 1**: unit tests for `GapDetector` (seeded timelines with known gaps/edge cases: new accounts, dormant accounts, December boundaries); live run `zoho-bookkeeper audit --year 2025` against the real org — the AMEX/Chase/Citi accounts have years of data; sanity-check flagged gaps against Zoho's web UI.
- **Phase 2**: unit tests for `ReceiptMatcher` (exact/tolerance/date-window/ambiguous cases); end-to-end: forward one real receipt to billing@, run `receipts sync`, confirm the attachment appears on the expense in Zoho's web UI and the sidecar lands in the archive; share-extension test on device.
- **Phase 3**: `export --year 2025` bundle opens cleanly; coverage numbers cross-check against a manual Zoho count.
- All phases: `just test` stays green; CLI and app builds per `justfile` recipes.
