# ZohoAIBookkeeper

An AI-powered bookkeeping assistant that helps categorize uncategorized bank transactions in [Zoho Books](https://www.zoho.com/books/). It fetches your uncategorized transactions, asks Claude to suggest a transaction type / vendor / category / description for each one, refines that suggestion using your historical expense data, and then lets you review and confirm each transaction in an interactive terminal UI before it's written back to Zoho.

The **macOS CLI is the finished, daily-driver product.** iOS/iPadOS and watchOS app targets exist and compile, but they are partial scaffolding (see [Project status](#project-status)).

## How it works

For each uncategorized bank transaction, the `clean` command:

1. Sends the transaction (amount, description, payee, reference) to Claude along with your category list and known vendors.
2. Claude suggests a type (expense / transfer / owner contribution / sale / skip), a cleaned-up vendor name, a category, and a description, with a confidence score.
3. The suggestion is refined against history: if that vendor's prior expenses in Zoho mostly used one category, that category overrides Claude's guess (confidence bumped to 98%).
4. You review the suggestion in a full-screen terminal editor — cycle the type, pick vendor/category from searchable pickers, edit the description, or open the transaction in the Zoho web UI.
5. On save, the transaction is categorized in Zoho Books (creating the vendor if needed). Processed and skipped transaction IDs are cached in `~/.zoho-ai-bookeeper/cache.json` so they aren't shown again.

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

1. Copy the example config and fill in your credentials:

   ```sh
   cp Projects/BookkeeperCore/config.example.json Projects/BookkeeperCore/config.json
   ```

   `config.json` is gitignored. It contains your Zoho OAuth credentials, Anthropic API key, and an optional hierarchical category list (`categoryMapping`) used by the category picker. If `categoryMapping` is omitted, expense categories are fetched from your Zoho chart of accounts.

2. Generate the Xcode workspace and open it:

   ```sh
   make            # tuist install + generate, then open workspace
   ```

## Usage

```sh
make run        # build and launch the interactive CLI (clean command)
```

Or run the built binary directly:

```
zoho-bookkeeper clean [--account <id>] [--year <yyyy>] [--dry-run] [--verbose]
zoho-bookkeeper list-accounts
```

Editor keys: `Tab`/`↑↓` navigate · `Enter` select/edit · type to filter in pickers · `Esc` cancel · `Ctrl+Q` quit.

Other make targets: `make generate` (regenerate workspace without opening), `make open`, `make clean` (nuke workspace, DerivedData, Tuist cache).

## Project layout

| Path | What it is |
|---|---|
| `Projects/BookkeeperCore` | Shared framework (iOS/macOS/watchOS): models, Claude service, history matcher, cache, view models |
| `Projects/CLI` | `ZohoBookkeeperCLI` — the macOS terminal app (ArgumentParser + custom raw-mode TUI) |
| `Projects/App` | `ZohoBookkeeperApp` — SwiftUI iPhone/iPad app (scaffolding) |
| `Projects/Watch` | `ZohoBookkeeperWatch` — watchOS app + pending-count complication (scaffolding) |
| `Tuist/`, `Workspace.swift` | Tuist manifests; dependencies: ZohoBooksClient (local), SwiftAnthropic, swift-argument-parser |

## Project status

- **CLI** — works end to end; this is what gets used.
- **iOS app** — compiles for the simulator and has real views (dashboard, account list, transaction list/editor, settings), but credentials are not persisted between launches (Keychain storage is a TODO) and the AI-suggestion button isn't wired to the Claude service yet. Building out a usable iPhone/iPad app is the main future direction, since categorizing expenses on the go is more practical than at a desk. The CLI stays.
- **Watch app** — compiles; UI shell and complication exist but show placeholder data (no Watch Connectivity or shared data source yet).

See `CODE_REVIEW.md` for a detailed code-quality assessment and known bugs, and `CLAUDE.md` for contributor/agent-oriented documentation.
