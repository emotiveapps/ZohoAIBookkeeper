// BookkeeperCore - Shared business logic for ZohoAIBookkeeper
//
// This module provides shared functionality across all platforms:
// - iOS app
// - macOS CLI
// - watchOS complication
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
//   - TransactionType.swift
//   - TransactionSuggestion.swift
//   - Configuration.swift
//
// Services/
//   - ClaudeService.swift
//   - CacheService.swift
//   - TransferDetector.swift
//
// ViewModels/
//   - TransactionListViewModel.swift
//   - TransactionEditorViewModel.swift
//   - DashboardViewModel.swift
