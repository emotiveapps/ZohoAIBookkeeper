import Foundation
import ZohoBooksClient

/// The single implementation of "write this categorization decision to Zoho Books."
/// Both the CLI and the iOS app must route saves through this type so their behavior can't drift.
public struct TransactionCategorizer: Sendable {
    /// Zoho account names used for the non-expense flows.
    public struct AccountNames: Sendable {
        public var ownersEquity: String
        public var sales: String

        public init(ownersEquity: String = "Owner's Equity", sales: String = "Sales") {
            self.ownersEquity = ownersEquity
            self.sales = sales
        }
    }

    private let client: ZohoBooksClient<ZohoOAuth>
    private let accountNames: AccountNames

    public init(client: ZohoBooksClient<ZohoOAuth>, accountNames: AccountNames = AccountNames()) {
        self.client = client
        self.accountNames = accountNames
    }

    /// Writes the transaction's selected categorization to Zoho Books.
    ///
    /// Everything except `.skip` is writable; `.skip` throws
    /// `CategorizationError.typeNotCategorizable` — callers must handle it
    /// locally (mark skipped) instead of pretending it was saved.
    ///
    /// - Returns: the vendor name that was created/attached, if any (for cache updates).
    @discardableResult
    public func categorize(_ transaction: CategorizedTransaction) async throws -> String? {
        let tx = transaction.transaction

        switch transaction.selectedType {
        case .expense:
            var vendorId: String?
            var attachedVendorName: String?
            if !transaction.vendorName.isEmpty {
                let vendor = try await client.getOrCreateVendor(name: transaction.vendorName)
                vendorId = vendor.contactId
                attachedVendorName = transaction.vendorName
            }

            let categoryAccount = try await requireAccount(named: transaction.category)

            let request = ZBCategorizeExpenseRequest(
                accountId: categoryAccount,
                vendorId: vendorId,
                paidThroughAccountId: tx.accountId,
                description: transaction.description,
                date: tx.date,
                amount: tx.amount
            )
            try await client.categorizeAsExpense(transactionId: tx.transactionId, request: request)
            return attachedVendorName

        case .transfer:
            guard let otherAccountId = transaction.transferToAccountId, !otherAccountId.isEmpty else {
                throw CategorizationError.transferTargetMissing
            }
            guard let ownAccountId = tx.accountId, !ownAccountId.isEmpty else {
                throw CategorizationError.transferSourceMissing
            }
            // Zoho requires both endpoints of the transfer plus the date.
            // Direction must respect credit-card inversion: on a credit card a
            // debit is money arriving (it reduces the liability), the opposite
            // of a bank account.
            let moneyOut = TransactionType.isUserExpense(
                isDebit: tx.isDebit,
                accountType: tx.accountType ?? "bank"
            )
            let request = ZBCategorizeTransferRequest(
                toAccountId: moneyOut ? otherAccountId : ownAccountId,
                fromAccountId: moneyOut ? ownAccountId : otherAccountId,
                amount: tx.amount,
                date: tx.date,
                referenceNumber: tx.referenceNumber,
                description: transaction.description
            )
            try await client.categorizeAsTransfer(transactionId: tx.transactionId, request: request)
            return nil

        case .cardPayment:
            guard let otherAccountId = transaction.transferToAccountId, !otherAccountId.isEmpty else {
                throw CategorizationError.transferTargetMissing
            }
            guard let ownAccountId = tx.accountId, !ownAccountId.isEmpty else {
                throw CategorizationError.transferSourceMissing
            }
            // Same orientation rules as a transfer: money-out pays the picked
            // card; money-in is a payment arriving onto this card.
            let paymentOut = TransactionType.isUserExpense(
                isDebit: tx.isDebit,
                accountType: tx.accountType ?? "bank"
            )
            let request = ZBCategorizeCardPaymentRequest(
                toAccountId: paymentOut ? otherAccountId : ownAccountId,
                fromAccountId: paymentOut ? ownAccountId : otherAccountId,
                amount: tx.amount,
                date: tx.date,
                referenceNumber: tx.referenceNumber,
                description: transaction.description
            )
            try await client.categorizeAsCardPayment(transactionId: tx.transactionId, request: request)
            return nil

        case .ownerContribution:
            let equityAccountId = try await requireAccount(named: accountNames.ownersEquity)
            let request = ZBCategorizeOwnerContributionRequest(
                accountId: equityAccountId,
                description: transaction.description
            )
            try await client.categorizeAsOwnerContribution(transactionId: tx.transactionId, request: request)
            return nil

        case .sale:
            let salesAccountId = try await requireAccount(named: accountNames.sales)
            let request = ZBCategorizeSaleRequest(
                accountId: salesAccountId,
                description: transaction.description
            )
            try await client.categorizeAsSale(transactionId: tx.transactionId, request: request)
            return nil

        case .refund:
            var vendorId: String?
            var attachedVendorName: String?
            if !transaction.vendorName.isEmpty {
                let vendor = try await client.getOrCreateVendor(name: transaction.vendorName)
                vendorId = vendor.contactId
                attachedVendorName = transaction.vendorName
            }

            // The category names the expense account the money comes back to.
            let categoryAccount = try await requireAccount(named: transaction.category)

            let request = ZBCategorizeExpenseRefundRequest(
                accountId: categoryAccount,
                vendorId: vendorId,
                date: tx.date,
                amount: tx.amount,
                description: transaction.description
            )
            try await client.categorizeAsExpenseRefund(transactionId: tx.transactionId, request: request)
            return attachedVendorName

        case .skip:
            throw CategorizationError.typeNotCategorizable(transaction.selectedType)
        }
    }

    private func requireAccount(named name: String) async throws -> String {
        guard let account = try await client.searchAccountByName(name),
              let accountId = account.accountId, !accountId.isEmpty else {
            throw CategorizationError.accountNotFound(name: name)
        }
        return accountId
    }
}
