# ZohoAIBookkeeper

An AI-powered bookkeeping assistant that automatically categorizes uncategorized bank transactions in [Zoho Books](https://www.zoho.com/books/) using [Claude](https://www.anthropic.com/claude). Available as an iOS/macOS app, a CLI tool, and a watchOS companion.

## Features

- **AI-Powered Categorization** -- Uses Claude to suggest transaction categories, vendors, and types (expense, transfer, owner contribution, sale, refund) with confidence levels
- **Smart History Matching** -- Learns from past vendor categorization in Zoho Books to refine AI suggestions
- **Transfer Detection** -- Automatically detects inter-account transfers by matching descriptions and account names
- **Multi-Platform** -- Shared core framework powers an iOS app, macOS app, interactive CLI, and watchOS complication
- **Caching** -- Tracks processed and skipped transactions to avoid re-processing

## Architecture

The project uses [Tuist](https://tuist.io) for project generation and is organized into:

| Target | Description |
|---|---|
| **BookkeeperCore** | Shared framework with models, services, and view models |
| **App** (iOS/macOS) | SwiftUI app with dashboard, account list, and transaction editor |
| **CLI** | Interactive terminal tool with spinners and keyboard navigation |
| **Watch** (watchOS) | Complication showing pending transaction count |

## Requirements

- macOS 11+ / iOS 14+ / watchOS 9+
- Swift 6.0+
- [mise](https://mise.jdx.dev) (manages Tuist automatically via `.mise.toml`)
- A Zoho Books account with API credentials
- An Anthropic API key

## Setup

1. **Create your configuration file:**
   ```bash
   cp Projects/BookkeeperCore/config.example.json Projects/BookkeeperCore/config.json
   ```
   Then fill in your Zoho Books credentials and Anthropic API key. Supported Zoho regions: `com`, `eu`, `in`, `au`.

3. **Generate the Xcode workspace:**
   ```bash
   make generate
   ```

4. **Authenticate with Zoho:**
   ```bash
   # First, add http://localhost:8484/callback as an Authorized Redirect URI
   # in your Zoho API Console (https://api-console.zoho.com)
   make run -- login
   ```
   This opens your browser for OAuth consent, then saves the tokens to `config.json`.

## Usage

### CLI

```bash
# Authenticate with Zoho (first time or to re-authorize)
ZohoBookkeeperCLI login [--port 8484] [--config-path PATH]

# Build and run the interactive categorization tool
make run

# Or after building, run directly:
ZohoBookkeeperCLI clean [--account ACCOUNT_ID] [--year 2024] [--dry-run] [--verbose]
ZohoBookkeeperCLI list-accounts [--verbose]
```

The `clean` command walks through uncategorized transactions one at a time, showing AI-suggested categories that you can accept, edit, or skip.

### iOS / macOS App

```bash
make generate
make open
```

Then build and run the **App** scheme in Xcode.

## Make Targets

| Command | Description |
|---|---|
| `make generate` | Install dependencies and generate the Xcode workspace |
| `make open` | Open the workspace in Xcode |
| `make run` | Build and run the CLI |
| `make clean` | Remove all generated files, build artifacts, and caches |

## Configuration

See [`config.example.json`](Projects/BookkeeperCore/config.example.json) for the full template. Key sections:

- **zoho** -- OAuth credentials and organization ID for Zoho Books
- **anthropic** -- Your Claude API key
- **category_mapping** -- Hierarchical expense categories with optional sub-categories
