import Foundation
import Testing
@testable import BookkeeperCore

@Suite("Claude response parsing")
struct ClaudeResponseParsingTests {

    private func makeService() -> ClaudeService {
        ClaudeService(apiKey: "test-key", categories: ["Software", "Meals"])
    }

    @Test("Bare JSON ending exactly with a brace parses (former crash, B1)")
    func bareJSON() async {
        let response = """
        {"transaction_type": "expense", "vendor_name": "Amazon", "category": "Software", \
        "description": "AWS bill", "confidence": 92, "reasoning": "Known vendor"}
        """
        let suggestion = await makeService().parseClaudeResponse(response)
        #expect(suggestion.transactionType == .expense)
        #expect(suggestion.vendorName == "Amazon")
        #expect(suggestion.category == "Software")
        #expect(suggestion.confidence == 92)
    }

    @Test("Markdown-fenced JSON parses")
    func fencedJSON() async {
        let response = """
        Here is my suggestion:
        ```json
        {"transaction_type": "transfer", "transfer_to_account": "Savings", "confidence": 70, "reasoning": "Transfer keyword"}
        ```
        """
        let suggestion = await makeService().parseClaudeResponse(response)
        #expect(suggestion.transactionType == .transfer)
        #expect(suggestion.transferToAccount == "Savings")
    }

    @Test("Unparseable response degrades to a zero-confidence expense")
    func garbage() async {
        let suggestion = await makeService().parseClaudeResponse("I'm not sure about this one.")
        #expect(suggestion.transactionType == .expense)
        #expect(suggestion.confidence == 0)
        #expect(suggestion.category == "Uncategorized")
    }

    @Test("Unknown transaction type falls back to expense")
    func unknownType() async {
        let suggestion = await makeService().parseClaudeResponse(
            #"{"transaction_type": "dividend", "confidence": 40, "reasoning": "?"}"#
        )
        #expect(suggestion.transactionType == .expense)
        #expect(suggestion.confidence == 40)
    }

    @Test("Zoho raw values for type are accepted")
    func zohoRawTypes() async {
        let sale = await makeService().parseClaudeResponse(
            #"{"transaction_type": "sales_without_invoices", "confidence": 60, "reasoning": "-"}"#
        )
        #expect(sale.transactionType == .sale)

        let transfer = await makeService().parseClaudeResponse(
            #"{"transaction_type": "transfer_fund", "confidence": 60, "reasoning": "-"}"#
        )
        #expect(transfer.transactionType == .transfer)
    }
}

@Suite("Configuration")
struct ConfigurationTests {

    @Test("config.json snake_case payload parses, including category mapping")
    func parseConfig() throws {
        let json = """
        {
          "zoho": {
            "client_id": "cid", "client_secret": "cs",
            "access_token": "at", "refresh_token": "rt",
            "organization_id": "123", "region": "com"
          },
          "anthropic": {"api_key": "ak"},
          "category_mapping": {
            "categories": [
              {"name": "Operations", "children": ["Software", "Office Supplies"]},
              {"name": "Travel"}
            ]
          }
        }
        """
        let config = try ConfigLoader.parse(Data(json.utf8))
        #expect(config.zoho.organizationId == "123")
        #expect(config.anthropic.apiKey == "ak")
        #expect(config.categoryMapping?.allCategoryNames == ["Operations", "Software", "Office Supplies", "Travel"])
    }

    @Test("Zoho web URL keeps query inside the SPA fragment")
    func transactionURL() {
        let config = FullConfiguration(
            zoho: ZohoConfiguration(
                clientId: "c", clientSecret: "s", accessToken: "a",
                refreshToken: "r", organizationId: "999", region: "com"
            ),
            anthropic: AnthropicConfiguration(apiKey: "k")
        )
        let url = config.transactionURL(bankAccountId: "acc1", transactionId: "tx1", isDebit: true)
        let string = url?.absoluteString ?? ""
        #expect(string.hasPrefix("https://books.zoho.com/app/999#/banking/transactions/details?"))
        #expect(string.contains("transaction_id=tx1"))
        #expect(string.contains("txn_group=money_out"))
    }
}

@Suite("Ledger semantics")
struct LedgerSemanticsTests {

    // Zoho reports debit_or_credit in ledger terms for every account type:
    // credit = money leaving the user's pocket, debit = money arriving
    // (verified against live org data on both bank and credit_card accounts).

    @Test("On credit cards, credits (purchases) are user expenses")
    func creditCardCredits() {
        #expect(TransactionType.isUserExpense(isDebit: false, accountType: "credit_card"))
        #expect(!TransactionType.isUserExpense(isDebit: true, accountType: "credit_card"))
        #expect(TransactionType.availableTypes(isDebit: false, accountType: "credit_card") == TransactionType.debitTypes)
    }

    @Test("On bank accounts, credits (withdrawals) are user expenses too")
    func bankCredits() {
        #expect(TransactionType.isUserExpense(isDebit: false, accountType: "bank"))
        #expect(!TransactionType.isUserExpense(isDebit: true, accountType: "bank"))
        #expect(TransactionType.availableTypes(isDebit: true, accountType: "bank") == TransactionType.creditTypes)
    }
}
