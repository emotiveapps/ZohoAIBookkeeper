// BookkeeperCore - Shared business logic for ZohoAIBookkeeper
//
// This module provides shared functionality across all platforms:
// - macOS CLI (the primary product)
// - iOS/iPadOS app
// - watchOS app + complication
//

@_exported import ZohoBooksClient

// MARK: - Re-exports

// Models
public typealias BankAccount = ZBBankAccount
public typealias BankTransaction = ZBBankTransaction
public typealias Contact = ZBContact

// This file serves as the main entry point for the framework.
// All public types are defined in their respective files:
//
// Models/
//   - TransactionType.swift        Zoho transaction types + credit-card semantics
//   - TransactionSuggestion.swift  AI suggestion + editable draft
//   - Configuration.swift          config.json schema + Zoho web links
//
// Services/
//   - ClaudeService.swift          prompt -> JSON suggestion via SwiftAnthropic
//   - HistoryMatcher.swift         vendor-history refinement of suggestions
//   - SuggestionPipeline.swift     ClaudeService + HistoryMatcher in one call
//   - TransactionCategorizer.swift the single "write decision to Zoho" path
//   - CacheService.swift           processed/skipped/vendor cache on disk
//   - CredentialsStore.swift       Keychain-backed credential storage (apps)
//   - ConfigLoader.swift           file-based config loading (CLI)
//   - Logger.swift                 stderr diagnostics
