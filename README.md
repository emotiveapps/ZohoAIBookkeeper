# ZohoAIBookkeeper

An AI-powered bookkeeping assistant that helps categorize uncategorized bank transactions in [Zoho Books](https://www.zoho.com/books/). It fetches your uncategorized transactions, asks Claude to suggest a transaction type / vendor / category / description for each one, refines that suggestion using your historical expense data, and then lets you review and confirm each transaction before it's written back to Zoho.

Two front ends share one engine (`BookkeeperCore`): the **macOS CLI** (interactive terminal UI) and the **iPhone/iPad app** (triage-style review flow, credentials in the Keychain). A watchOS app + complication shows the pending count synced from the phone.

## How it works

For each uncategorized bank transaction, the `clean` command:

1. Sends the transaction (amount, description, payee, reference) to Claude along with your category list and known vendors.
2. Claude suggests a type (expense / transfer / owner contribution / sale / skip), a cleaned-up vendor name, a category, and a description, with a confidence score.
3. The suggestion is refined against history: if that vendor's prior expenses in Zoho mostly used one category, that category overrides Claude's guess (confidence bumped to 98%).
4. You review the suggestion in a full-screen terminal editor — cycle the type, pick vendor/category from searchable pickers, edit the description, or open the transaction in the Zoho web UI.
5. On save, the transaction is categorized in Zoho Books (creating the vendor if needed). Processed and skipped transaction IDs are cached (macOS: `~/.zoho-ai-bookkeeper/cache.json`; iOS: app documents) so they aren't shown again.

The iPhone/iPad app runs the same loop as a one-transaction-at-a-time review screen with the next suggestion prefetched while you decide, so advancing feels instant.

## Requirements

- macOS 14+ with Xcode installed (project is currently pinned to Xcode ≤ 27.x via `Tuist.swift`)
- [Tuist](https://tuist.dev) (installed automatically via [mise](https://mise.jdx.dev): `mise install`)
- The **ZohoBooksClient** package checked out as a sibling directory:

  ```
  Development/experiments/
  ├── ZohoAIBookkeeper/   ← this repo
  └── ZohoBooksClient/    ← required local dependency
  ```

- A Zoho Books account with API credentials (client ID/secret, OAuth tokens, organization ID)
- An Anthropic API key

## Setup

1. **CLI**: copy the example config into your home directory and fill in your credentials:

   ```sh
   mkdir -p ~/.zoho-ai-bookkeeper
   cp Projects/BookkeeperCore/config.example.json ~/.zoho-ai-bookkeeper/config.json
   ```

   It contains your Zoho OAuth credentials, Anthropic API key, and an optional hierarchical category list (`category_mapping`) used by the category picker; omit it and expense categories are fetched from your Zoho chart of accounts. Set `ZOHO_BOOKKEEPER_CONFIG` to point somewhere else. (The config is deliberately *not* bundled into built products — it holds real secrets.)

2. **iPhone/iPad app**: no file needed — on first launch, paste the contents of your `config.json` into Setup (or type the credentials) and they're stored in the device Keychain.

3. Generate the Xcode workspace and open it:

   ```sh
   just            # tuist install + generate, then open workspace
   ```

## Usage

```sh
just run        # build and launch the interactive CLI (clean command)
```

Or run the built binary directly:

```
zoho-bookkeeper clean [--account <id>] [--year <yyyy>] [--dry-run] [--verbose]
zoho-bookkeeper list-accounts
zoho-bookkeeper audit --year 2025 [--receipts] [--export]   # tax-readiness report; exits 2 on blockers
zoho-bookkeeper gaps --year 2025 [--account <id>]           # bank-feed outage detection w/ sparklines
zoho-bookkeeper cogs --year 2025 --ending-inventory 5000    # periodic COGS for inventory resale
```

`audit --export` writes markdown + CSVs to `./reports/<year>/` (override with `--output`; the directory is gitignored since it holds real financial data) for your accountant. Inventory purchases (e.g. LEGO bought for resale) are categorized to Inventory/COGS accounts at purchase time and deducted via COGS at year-end — the pickers and AI suggestions understand this.

Editor keys: `Tab`/`↑↓` navigate · `Enter` select/edit · type to filter in pickers · `Esc` cancel · `Ctrl+Q` quit.

Other recipes (`just --list` for all): `just generate` (regenerate workspace without opening), `just open`, `just test` / `just test-app` (unit tests), `just clean` (nuke workspace, DerivedData, Tuist cache). Both `just` and `tuist` are installed by [mise](https://mise.jdx.dev) via `.mise.toml` — run `mise install` once.

## Project layout

| Path | What it is |
|---|---|
| `Projects/BookkeeperCore` | Shared framework (iOS/macOS/watchOS): models, Claude suggestion pipeline, history matcher, categorizer, cache, Keychain store |
| `Projects/CLI` | `ZohoBookkeeperCLI` — the macOS terminal app (ArgumentParser + custom raw-mode TUI) |
| `Projects/App` | `ZohoBookkeeperApp` — SwiftUI iPhone/iPad app (design notes in `Projects/App/DESIGN.md`) |
| `Projects/Watch` | `ZohoBookkeeperWatch` — watchOS app + pending-count complication (synced from the phone) |
| `Tuist/`, `Workspace.swift` | Tuist manifests; dependencies: ZohoBooksClient (local), SwiftAnthropic, swift-argument-parser |

## Testing

```sh
just test       # BookkeeperCore unit tests (macOS, 30 tests)
just test-app   # app unit tests (iOS simulator)
```

## Project status

- **CLI** — works end to end; the original daily driver.
- **iOS/iPad app** — rewritten (Aug 2026) around a triage-first review flow: Keychain-persisted credentials, live AI suggestions with prefetch, searchable hierarchical category picker, vendor creation, adaptive iPhone/iPad layout. Builds and unit-tests clean; needs a run on a real device against live data to shake out UX.
- **Watch app** — shows the real pending count synced from the iPhone via Watch Connectivity; the complication reads the same stored value.

See `CODE_REVIEW.md` for the code-quality review and the resolution log of everything fixed since, and `CLAUDE.md` for contributor/agent-oriented documentation.
