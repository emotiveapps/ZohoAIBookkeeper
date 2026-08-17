# CLAUDE.md — agent guide for ZohoAIBookkeeper

Detailed orientation for AI agents (and humans who want the long version). The human-facing overview is `README.md`; `CODE_REVIEW.md` holds the Aug 2026 quality review plus the resolution log of every fix made since (useful history for why the code looks the way it does).

## What this project is

A personal bookkeeping tool that categorizes uncategorized Zoho Books bank transactions with help from the Anthropic API. One shared framework (`BookkeeperCore`) feeds three front ends: the **macOS CLI** (original product, works end to end), the **iOS/iPadOS SwiftUI app** (rewritten Aug 2026 — triage-first review flow, fully wired; see `Projects/App/DESIGN.md` for the design rationale), and a watchOS app + complication (pending count synced from the phone).

**Owner's direction (Aug 2026):** the iPhone/iPad app is the priority — expenses mostly get categorized on the go. The CLI must keep working; don't break it while evolving the app. Both must route Zoho writes through the shared `TransactionCategorizer` so behavior can't drift.

## Build system

- **Tuist** generates the Xcode workspace from manifests. Never edit `.xcodeproj`/`.xcworkspace` by hand — they're generated and gitignored. Edit `Workspace.swift`, `Projects/*/Project.swift`, or `Tuist/ProjectDescriptionHelpers/Project+Templates.swift`, then **re-run `just generate`** (required after adding/removing source files — globs are resolved at generation time; a stale project fails with "Build input file cannot be found").
- `Tuist/Package.swift` declares dependencies: **`../../ZohoBooksClient` (a local sibling checkout — required; it has its own `CODE_REVIEW.md`)**, `SwiftAnthropic`, `swift-argument-parser`. If `ZohoBooksClient` is missing next to this repo, nothing builds.
- Tuist installs via mise (`.mise.toml`). Tuist Cloud was deliberately removed to save money — don't reintroduce `fullHandle` in `Tuist.swift`.
- `Tuist.swift` pins `compatibleXcodeVersions: .upToNextMajor("27.0")`, Swift 6.0 (strict concurrency is in force — see conventions).

### Commands

Task runner is `just` (recipes in `justfile`; both `just` and `tuist` are pinned in `.mise.toml` — `mise install` sets them up):

```sh
just            # tuist install + generate + open Xcode
just generate   # generate workspace only (does NOT open Xcode — intentional)
just run        # build ZohoBookkeeperCLI (Debug, arm64) and run it with DYLD_FRAMEWORK_PATH set
just test       # BookkeeperCore unit tests (macOS)
just test-app   # app unit tests (iOS simulator)
just lint       # SwiftLint over Projects/ (same binary+config as the Xcode build phase)
just lint-fix   # SwiftLint autocorrect, then report what remains
just clean      # kill Xcode, delete workspace/projects/DerivedData/Tuist cache

# Direct builds
xcodebuild -workspace ZohoAIBookkeeper.xcworkspace -scheme ZohoBookkeeperCLI \
  -configuration Debug -destination "platform=macOS,arch=arm64" build -quiet
xcodebuild -workspace ZohoAIBookkeeper.xcworkspace -scheme ZohoBookkeeperApp \
  -configuration Debug -destination "generic/platform=iOS Simulator" build -quiet
xcodebuild -workspace ZohoAIBookkeeper.xcworkspace -scheme ZohoBookkeeperWatch \
  -configuration Debug -destination "generic/platform=watchOS Simulator" build -quiet

# Tests (see Testing below)
xcodebuild ... -scheme ZohoBookkeeperCLI -destination "platform=macOS,arch=arm64" test
xcodebuild ... -scheme ZohoBookkeeperApp -destination "platform=iOS Simulator,name=iPhone 17" test
```

### Environment gotchas (verified Aug 2026)

- **`xcode-select` may point at CommandLineTools**, which makes `tuist generate` fail with "Couldn't find Xcode's Info.plist at /Library/Contents/Info.plist". Fix without sudo: `export DEVELOPER_DIR=/Applications/Xcode-<version>.app/Contents/Developer` before any tuist/xcodebuild command (Xcode is installed as a versioned bundle, e.g. `Xcode-27.0.0-Beta.5.app`). Persistent fix: `sudo xcode-select -s`.
- Running the CLI binary outside `just run` requires `DYLD_FRAMEWORK_PATH` pointing at the Debug products dir (frameworks are dynamic, not embedded).
- The `ZohoAIBookkeeper-All` scheme on a plain macOS destination fails on **provisioning** for the iOS/watch app targets. Build per-scheme with the right destination. Signing: team `M7T8YXH895`, bundle prefix `com.emotiveapps`. Test bundles use ad-hoc signing (set in `Project+Templates.swift`) so `xcodebuild test` needs no certificate.
- Simulator tests can fail with "Simulator device failed to launch" if the sim is cold; `xcrun simctl boot "iPhone 17"` first, then run tests.
- Linting: SwiftLint is pinned via mise (`.mise.toml`) so the terminal (`just lint`), the Xcode build phase (a `TargetScript` in `Project+Templates.swift`), and future CI all run the identical binary + repo-root `.swiftlint.yml`. Thresholds are tuned so errors are rare and builds stay green; warnings nag (legacy TUI is the main offender). `swiftlint` itself needs `DEVELOPER_DIR` pointing at full Xcode (SourceKit). `ENABLE_USER_SCRIPT_SANDBOXING` is deliberately NO so the lint phase can read the source tree. `.swiftformat` also lives at repo root.

## Configuration & secrets

Two credential paths, deliberately separate:

- **CLI**: the real config is **`config.json` at the repo root** — gitignored, snake_case JSON, template at `Projects/BookkeeperCore/config.example.json`. **Owner's policy (Aug 2026): config lives in the repo, never in a home-directory dotfolder** — it survives `just clean`/rebuilds and dies with the repo. The receipts audit archive is cloud-canonical in OneDrive (`03_Finance/ZohoAIBookkeeper/Receipts Archive`, synced via `GraphDriveSyncEngine` with local cache/staging in `~/Library/Caches` / Application Support); only logs and the installed binary belong under `~/.zoho-ai-bookkeeper/`. `ConfigLoader` reads `$ZOHO_BOOKKEEPER_CONFIG` if set, else walks up from the cwd looking for `config.json`; the installed CLI's `zoho-bookkeeper` wrapper (written by `just install`) pins the env var to this repo's path. Fields: `zoho` (clientId/clientSecret/accessToken/refreshToken/organizationId/region), `anthropic.api_key`, `receipts` (mailboxes + onedrive), optional `category_mapping.categories[]` (`{name, children[]}`) feeding the hierarchical pickers. **Never make config.json a bundled resource again** — it used to be one, which baked real secrets into every built product (fixed as M7).
- **App**: `KeychainCredentialsStore` (BookkeeperCore) persists the whole `FullConfiguration` as one Keychain item, behind the `CredentialsStore` protocol; `InMemoryCredentialsStore` backs tests/previews. Setup accepts pasted config.json (via `ConfigLoader.parse`) or manual entry, and verifies against Zoho before saving.

## Architecture

```
ZohoBooksClient (sibling repo: actor-based API client, OAuth refresh, ZB* models)
        ▲
BookkeeperCore (framework; @_exported imports ZohoBooksClient)
  Models/      TransactionType (Zoho raw values; credit-card semantics helpers)
               TransactionSuggestion + CategorizedTransaction (editable draft)
               Configuration (config schema, Zoho web-link builder)
  Services/    GapDetector (pure cadence-based feed-outage detection)
               TaxReadinessAuditor (per-year completeness report; inventory/COGS
                                    split; opt-in receipt-coverage check)
               TaxReadinessReportFormatter (markdown/CSV) + CategoryFilter
                                    (expense + inventory/COGS account sourcing)
               MicrosoftGraphMailClient (Microsoft Graph device-code OAuth + shared-mailbox
                                reading; tokens in Keychain per tenant+mailbox)
               ReceiptParser (Claude extraction: PDF/image native, HTML stripped;
                              Haiku default) / ReceiptMatcher (pure matching) /
               ReceiptStore (audit archive + sidecars) / ReceiptPipeline (sync
                             orchestration, hold & retry)
               ClaudeService (actor: prompt → JSON suggestion; parser is internal for tests)
               HistoryMatcher (actor: vendor-history overrides; VendorHistorySource
                               protocol seam — ZohoVendorHistorySource in prod, stub in tests)
               SuggestionPipeline (actor: Claude + history in one call — the ONLY way
                                   either front end should get suggestions)
               TransactionCategorizer (the ONLY write path to Zoho; typed
                                       CategorizationError instead of empty IDs;
                                       refuses .refund/.skip)
               CacheService (actor: processed/skipped/vendors; macOS ~/.zoho-ai-bookkeeper,
                             iOS documents dir)
               CredentialsStore / KeychainCredentialsStore / InMemoryCredentialsStore
               ConfigLoader (CLI file config), Logger (stderr)
  Extensions/  AnthropicModel (model IDs + latest* shortcuts; default .latestSonnet)
        ▲
  CLI   ZohoBookkeeperCLI.swift (`clean` + `list-accounts`; review loop with
        do/catch-guarded cache saves)
        AuditCommands.swift (`audit` / `gaps` / `cogs` — tax-readiness reports,
        feed-gap sparklines, periodic COGS; exports to ./reports/<year>/ by
        default (--output overrides; gitignored — real financial data))
        TUI/ Terminal (raw mode, ANSI, lock-serialized output), TransactionEditor,
        SearchablePicker, TerminalSpinner
  App   App/  AppModel (@Observable lifecycle: loading → needsSetup → ready(Workspace)),
              Workspace (connected clients + reference data + pending counts),
              ReviewSession (per-account queue, one-ahead suggestion prefetch),
              WatchSync (WCSession sender)
        Views/ RootView, SetupView (paste-import or manual), HomeView
              (NavigationSplitView: accounts + stats), ReviewView (triage screen),
              PickerSheets (searchable category/vendor), SettingsView, Components
  Watch ZohoBookkeeperWatchApp (WatchState + PhoneSyncReceiver: WCSession receiver,
        persists count for the complication), ContentView, PendingCountComplication
```

**Zoho API quirks (verified live, Aug 2026 — cost us a whole debugging saga):**
- `/banktransactions` listings **exclude uncategorized statement lines** unless queried with `status=uncategorized` — `filter_by=Status.All` does NOT mean all. `ZohoBooksClient.fetchTransactions(status: .all)` handles the merge; never query the raw endpoint expecting completeness.
- `date_start`/`date_end` are **ignored** on those listings — always filter by date client-side (GapDetector and TaxReadinessAuditor do).
- Uncategorized lines can't be DELETEd via API; use `POST /banktransactions/uncategorized/{id}/exclude` (reversible via Restore in the UI). Used to purge ~154 duplicate lines in Aug 2026 (audit logs in `tmp/z_Archived/*.json`).
- `scripts/reconcile_statements.py` reconciles bank CSV exports against Zoho and emits statement-import files for missing transactions — extend its account table when new statements arrive (AMEX 2026 history pending).

Key invariants:

- **Credit-card semantics**: on `credit_card` accounts, credits are purchases. All direction logic must go through `TransactionType.isUserExpense(isDebit:accountType:)` / `availableTypes` — never raw `isDebit`.
- **Single write path**: every Zoho categorization goes through `TransactionCategorizer.categorize`. It throws `CategorizationError` (`accountNotFound` / `transferTargetMissing` / `typeNotCategorizable`) rather than sending empty account IDs. Callers handle `.skip` (mark skipped) and `.refund` (surface error) locally — never mark them processed.
- **Single suggestion path**: `SuggestionPipeline.suggestion(for:...)`. Don't call `ClaudeService`/`HistoryMatcher` directly from front ends.
- **Inventory/COGS (LEGO resale)**: inventory purchases are categorized to Inventory Asset/COGS accounts at purchase (recorded, documented, but not period expenses); deduction happens via periodic COGS (`cogs` command) at year-end. Category lists must come from `CategoryFilter.spendingCategories` so those accounts stay selectable. The tax-prep/audit-protection roadmap is `ROADMAP.md`; Phase 0/1/1.5 and Phase 2's email receipt pipeline are built and live-verified. Receipts flow: `receipts sync` never writes to Zoho unless a real expense exists (hold & retry); the archive is **cloud-canonical in OneDrive** (`receipts.archive_folder_path`, default `03_Finance/ZohoAIBookkeeper/Receipts Archive` — must NOT sit inside the swept folder), synced by `GraphDriveSyncEngine` (see `docs/ARCHIVE_SYNC_DESIGN.md`): purgeable local cache in `~/Library/Caches` (iOS: Caches container), pending uploads staged non-purgeably in Application Support, delta-token incremental pulls, staging-first writes so a cache purge can never lose a receipt. Never delete or rewrite archived files, only sidecar statuses. Mailbox contract: processed emails are **moved, never deleted**, into `Bookkeeper/{Matched,Pending,Needs Review,Not a Receipt}`; the Inbox is the to-process queue. A configured **OneDrive folder** (`receipts.onedrive.folder_path`, currently `03_Finance/Receipts` in the Lucky Frog OneDrive) is a second inbox with the same contract: `receipts sync` sweeps it via Graph (`/me/drive` of the signed-in account — cloud-side, independent of any Mac's sync client), processes only PDF/image files (scripts/CSVs/zips untouched), and moves processed files into the same four state subfolders **preserving their original subpath** (`2025-Q2/x.pdf` → `Matched/2025-Q2/x.pdf`). Graph calls send `Prefer: IdType="ImmutableId"` — don't remove it, stored message IDs depend on surviving moves; drive files are tracked by driveItem ID (stable across moves/renames). Entra scopes: delegated `Mail.ReadWrite.Shared` (folder create + move verified live) + `Files.ReadWrite` (OneDrive sweep); adding a scope requires re-consent via `receipts login --force`. Still open: emotiveapps mailbox, phases 3–4.
- **App state**: `@MainActor @Observable` classes (Observation framework, iOS 17+), not ObservableObject. The old `ViewModels/` layer is gone — don't recreate it; screen logic lives in `ReviewSession`/`Workspace`.

## Conventions

- **One type per file (owner's rule, Aug 2026): every top-level Swift type lives in its own file named exactly after the type.** Ask the owner's permission before ever co-locating types. Multi-type services group into a folder named for the service (e.g. `Services/ReceiptStore/` holds `ReceiptStore.swift`, `SyncStateStore.swift`, `FileSyncState.swift`, `UserDefaultsSyncState.swift`). Nested types inside a parent are fine. **Extensions are never defined inside another file** — they live in an `Extensions/` folder as `Type+Topic.swift` (e.g. `View+DecisionRow.swift`). Adding files requires `just generate`.
- Swift 6 language mode. Services are `actor`s; app models are `@MainActor @Observable`. `ClaudeService.service` keeps a justified `nonisolated(unsafe)` (SwiftAnthropic isn't Sendable) — don't "clean it up" without checking the region-isolation error it suppresses.
- `logger` writes to **stderr** (the TUI owns stdout). Keep logging out of hot TUI paths anyway.
- Zoho types are prefixed `ZB`; BookkeeperCore re-exports the module.
- Anthropic model IDs live only in `Extensions/AnthropicModel.swift`; 4.6+ models have **no dated IDs** (bare name is the ID). Keep `latest*` shortcuts current when adding models. Default stays Sonnet-tier per owner's cost preference.
- Commit style: short imperative summaries; the owner commits directly to main, no PR flow.

## Testing

34 Swift Testing tests: `BookkeeperCoreTests` (30, run via the **CLI scheme**, macOS destination) and `ZohoBookkeeperAppTests` (4, run via the **App scheme**, iOS Simulator). Coverage philosophy: the pure decision logic is what's tested — Claude response parsing, history matching (via the `VendorHistorySource` stub), cache persistence/corruption recovery, categorizer guards, credit-card semantics, config parsing, credential lifecycle. UI and network glue are deliberately not chased for coverage. If you add logic to BookkeeperCore, add tests in `Projects/BookkeeperCore/Tests/` — the seams (protocol sources, internal parser) exist precisely so that's easy; prefer extending a seam over hitting the network.
