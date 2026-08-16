# ZohoBookkeeperApp — design

*Rewrite, Aug 2026. Replaces the original scaffold (`AppState` + tab views), which compiled but was never wired: no credential persistence, AI suggestion unreachable, dashboard stats hardcoded.*

## Product framing

The job to be done is **inbox triage on the go**: a queue of uncategorized bank transactions, each needing a 10-second decision that the AI has mostly pre-made. The app is organized around that single loop; everything else (accounts, settings) exists to feed it.

Priorities, in order: (1) time-to-decision per transaction, (2) trust — always show what the AI decided and why, and what will be written to Zoho, (3) zero re-entry — credentials live in the Keychain, progress lives in the on-device cache.

## Screens

```
RootView  ──  phase switch
├─ .loading      ProgressView (Keychain read + connect at launch)
├─ .needsSetup   SetupView — paste config.json OR fill fields; saved to Keychain
└─ .ready        HomeView (NavigationSplitView)
                 ├─ Sidebar: accounts + pending badges, cache stats footer, settings gear
                 └─ Detail:  ReviewView for the selected account
                             └─ one transaction at a time:
                                amount/date/payee header → AI suggestion card
                                → editable Type / Category / Vendor / Description /
                                  Transfer-target → Save · Skip · progress "3 of 17"
```

- **iPad**: sidebar + review side by side (NavigationSplitView). **iPhone**: the same hierarchy collapses to a stack. No TabView — the account list *is* the navigation.
- **SetupView** offers two paths: paste the exact `config.json` JSON the CLI uses (fastest: AirDrop the file, copy, paste — also imports the category hierarchy), or type the six credential fields manually.
- **ReviewView** auto-advances after Save/Skip. While you review transaction *n*, the suggestion for *n+1* is already being fetched (`ReviewSession` prefetch) — the same trick the CLI's spinners approximate, but here it makes the next card appear instantly.
- Category and vendor pickers are searchable sheets; the category sheet shows the two-level hierarchy from `categoryMapping` when available, else the flat Zoho expense-account list. Vendor sheet allows free-text creation ("Use \"…\"").

## Architecture

- **`AppModel`** (`@MainActor @Observable`): owns lifecycle phase (`loading / needsSetup / ready`) and, when ready, a **`Workspace`** — the connected bundle of `ZohoBooksClient`, `ClaudeService`, `CacheService`, plus loaded accounts/categories/vendors/pending counts. Credentials go through **`CredentialsStore`** (protocol; `KeychainCredentialsStore` in production, `InMemoryCredentialsStore` for previews/tests).
- **`ReviewSession`** (`@MainActor @Observable`): per-account triage queue. Pulls uncategorized transactions (minus cached processed/skipped), runs the suggestion pipeline with one-ahead prefetch, holds the editable draft, and performs Save/Skip.
- **Shared logic lives in BookkeeperCore**, not in views:
  - `SuggestionPipeline` — Claude suggestion + history refinement in one call (used here; CLI adopts it too).
  - `TransactionCategorizer` — the *single* implementation of "write this decision to Zoho," with typed errors instead of empty-string account IDs. Replaces the two divergent copies that existed in the CLI and the old view model.
  - `KeychainCredentialsStore` — stores the whole `FullConfiguration` as one Keychain item.
- Old `ViewModels/` (ObservableObject) are deleted; app-layer state uses the Observation framework (iOS 17 target).

## Visual language

System-first: SF Symbols, semantic colors, `Form`/`List` where they fit, custom chrome only where it earns it (the transaction header card and confidence badge). Amounts are tinted by *user-perspective* direction via `TransactionType.isUserExpense` — red for money out, green for money in — which keeps credit-card semantics correct everywhere. Confidence: ≥80 green, ≥50 orange, else red, same thresholds as the CLI.
