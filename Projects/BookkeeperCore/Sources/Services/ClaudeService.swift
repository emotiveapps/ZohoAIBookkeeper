import Foundation
import SwiftAnthropic
import ZohoBooksClient

/// Service for getting transaction categorization suggestions from Claude
public actor ClaudeService {
    private nonisolated(unsafe) let service: any AnthropicService
    private let model: AnthropicModel
    private let categories: [String]
    private let verbose: Bool

    public init(apiKey: String, model: AnthropicModel = .latestSonnet, categories: [String], verbose: Bool = false) {
        self.service = AnthropicServiceFactory.service(
            apiKey: apiKey,
            betaHeaders: nil
        )
        self.model = model
        self.categories = categories
        self.verbose = verbose
    }

    /// Get a categorization suggestion for a bank transaction
    public func suggestCategorization(
        transaction: ZBBankTransaction,
        bankAccounts: [ZBBankAccount],
        existingVendors: [String]
    ) async throws -> TransactionSuggestion {
        let systemPrompt = buildSystemPrompt(bankAccounts: bankAccounts)
        let userPrompt = buildUserPrompt(transaction: transaction, existingVendors: existingVendors)

        if verbose {
            print("Asking Claude for categorization suggestion...")
        }

        let message = MessageParameter.Message(role: .user, content: .text(userPrompt))

        let parameters = MessageParameter(
            model: model.asModel,
            messages: [message],
            maxTokens: 1024,
            system: .text(systemPrompt)
        )

        let response: MessageResponse
        do {
            response = try await service.createMessage(parameters)
        } catch {
            logger.error("Anthropic API request failed: \(error)")
            throw error
        }

        // Extract text from the response
        var responseText = ""
        for content in response.content {
            if case let .text(text, _) = content {
                responseText = text
                break
            }
        }

        if responseText.isEmpty {
            return TransactionSuggestion(
                transactionType: .expense,
                category: "Uncategorized",
                confidence: 0,
                reasoning: "Failed to get response from Claude"
            )
        }

        return parseClaudeResponse(responseText)
    }

    private func buildSystemPrompt(bankAccounts: [ZBBankAccount]) -> String {
        let accountNames = bankAccounts.map { $0.accountName }.joined(separator: ", ")

        return """
        You are a bookkeeping assistant helping categorize bank transactions for a small business.

        Your task is to analyze each transaction and suggest:
        1. Transaction type (expense, transfer, owner_contribution, sale, or skip)
        2. Vendor name (clean, standardized name)
        3. Expense category from the available list
        4. A brief description

        Available expense categories:
        \(categories.joined(separator: "\n"))

        Available bank accounts (for detecting transfers):
        \(accountNames)

        Respond ONLY in this exact JSON format:
        {
          "transaction_type": "expense|transfer|owner_contribution|sale|skip",
          "vendor_name": "Clean Vendor Name",
          "category": "Category Name",
          "description": "Brief description",
          "transfer_to_account": "Account Name (only if transfer)",
          "confidence": 85,
          "reasoning": "Why you chose this categorization"
        }

        Guidelines:
        - For transfers: Look for keywords like "TRANSFER", bank names, or matches with other account names
        - For expenses: Match common vendor patterns (Amazon = Office Supplies or Cost of Goods Sold, etc.)
        - For owner contributions: Personal deposits, shareholder loans
        - For sales: Customer payments, revenue deposits
        - Use "skip" for unclear transactions that need manual review
        - Confidence should be 0-100 based on how certain you are
        - Always provide a clean, standardized vendor name (e.g., "AMAZON.COM*123456" -> "Amazon")
        """
    }

    private func buildUserPrompt(transaction: ZBBankTransaction, existingVendors: [String]) -> String {
        let vendorList = existingVendors.prefix(50).joined(separator: ", ")

        return """
        Categorize this bank transaction:

        Date: \(transaction.date)
        Amount: \(transaction.displayAmount) (\(transaction.isDebit ? "DEBIT/expense" : "CREDIT/income"))
        Description: \(transaction.description ?? "N/A")
        Payee: \(transaction.payee ?? "N/A")
        Reference: \(transaction.referenceNumber ?? "N/A")

        Existing vendors in the system (for matching):
        \(vendorList.isEmpty ? "None yet" : vendorList)

        Provide your categorization suggestion in JSON format.
        """
    }

    private func parseClaudeResponse(_ response: String) -> TransactionSuggestion {
        // Try to extract JSON from the response
        var jsonString = response

        // Handle markdown code blocks
        if let jsonStart = response.range(of: "{"),
           let jsonEnd = response.range(of: "}", options: .backwards) {
            jsonString = String(response[jsonStart.lowerBound...jsonEnd.upperBound])
        }

        struct ClaudeResponse: Codable {
            let transactionType: String?
            let vendorName: String?
            let category: String?
            let description: String?
            let transferToAccount: String?
            let confidence: Int?
            let reasoning: String?

            enum CodingKeys: String, CodingKey {
                case transactionType = "transaction_type"
                case vendorName = "vendor_name"
                case category
                case description
                case transferToAccount = "transfer_to_account"
                case confidence
                case reasoning
            }
        }

        do {
            let decoder = JSONDecoder()
            let parsed = try decoder.decode(ClaudeResponse.self, from: Data(jsonString.utf8))

            let txType: TransactionType
            switch parsed.transactionType?.lowercased() {
            case "expense": txType = .expense
            case "transfer", "transfer_fund": txType = .transfer
            case "owner_contribution": txType = .ownerContribution
            case "sale", "sales_without_invoices": txType = .sale
            case "refund": txType = .refund
            case "skip": txType = .skip
            default: txType = .expense
            }

            return TransactionSuggestion(
                transactionType: txType,
                vendorName: parsed.vendorName,
                category: parsed.category ?? "Uncategorized",
                description: parsed.description,
                transferToAccount: parsed.transferToAccount,
                confidence: parsed.confidence ?? 50,
                reasoning: parsed.reasoning ?? "No reasoning provided"
            )
        } catch {
            if verbose {
                logger.error("Failed to parse Claude response: \(error)")
                logger.debug("Raw response: \(response)")
            }

            return TransactionSuggestion(
                transactionType: .expense,
                category: "Uncategorized",
                confidence: 0,
                reasoning: "Failed to parse Claude response: \(error.localizedDescription)"
            )
        }
    }
}
