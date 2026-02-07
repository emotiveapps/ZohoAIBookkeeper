import Foundation
import ZohoBooksClient

/// Service for detecting inter-account transfers
public struct TransferDetector: Sendable {
    public let bankAccounts: [ZBBankAccount]
    public let verbose: Bool

    public init(bankAccounts: [ZBBankAccount], verbose: Bool = false) {
        self.bankAccounts = bankAccounts
        self.verbose = verbose
    }

    /// Check if a transaction appears to be a transfer based on its description
    /// - Parameter transaction: The transaction to check
    /// - Returns: The matching account if this looks like a transfer, nil otherwise
    public func detectTransfer(transaction: ZBBankTransaction) -> ZBBankAccount? {
        let description = (transaction.description ?? "").lowercased()
        let payee = (transaction.payee ?? "").lowercased()
        let combined = "\(description) \(payee)"

        // Common transfer keywords
        let transferKeywords = ["transfer", "xfer", "ach transfer", "wire transfer", "internal transfer"]
        let isTransferKeyword = transferKeywords.contains { combined.contains($0) }

        if verbose && isTransferKeyword {
            print("  Transfer keyword detected in: \(combined)")
        }

        // Check if description matches any account name
        for account in bankAccounts {
            // Skip the source account
            if account.accountId == transaction.accountId {
                continue
            }

            let accountName = account.accountName.lowercased()
            let accountWords = extractKeywords(from: accountName)

            // Check for account name match
            for word in accountWords where word.count >= 3 {
                if combined.contains(word) {
                    if verbose {
                        print("  Matched account '\(account.accountName)' via keyword '\(word)'")
                    }
                    return account
                }
            }

            // Check for bank name match
            if let bankName = account.bankName?.lowercased(), bankName.count >= 3 {
                if combined.contains(bankName) {
                    if verbose {
                        print("  Matched account '\(account.accountName)' via bank name '\(bankName)'")
                    }
                    return account
                }
            }
        }

        return nil
    }

    /// Find a matching transaction in another account (for transfer pairing)
    /// - Parameters:
    ///   - transaction: The original transaction
    ///   - otherTransactions: Transactions from other accounts to search
    /// - Returns: The matching transaction if found
    public func findMatchingTransaction(
        for transaction: ZBBankTransaction,
        in otherTransactions: [ZBBankTransaction]
    ) -> ZBBankTransaction? {
        let targetAmount = transaction.amount
        let targetDate = parseDate(transaction.date)

        guard let date = targetDate else { return nil }

        // Look for opposite transaction within 1 day
        let oneDayBefore = Calendar.current.date(byAdding: .day, value: -1, to: date)!
        let oneDayAfter = Calendar.current.date(byAdding: .day, value: 1, to: date)!

        for other in otherTransactions {
            // Skip same account
            if other.accountId == transaction.accountId {
                continue
            }

            // Check amount matches (opposite sign)
            guard abs(other.amount - targetAmount) < 0.01 else { continue }

            // Check dates are within range
            guard let otherDate = parseDate(other.date) else { continue }
            guard otherDate >= oneDayBefore && otherDate <= oneDayAfter else { continue }

            // Check opposite debit/credit
            if transaction.isDebit != other.isDebit {
                if verbose {
                    print("  Found matching transfer: \(other.displayDescription) on \(other.date)")
                }
                return other
            }
        }

        return nil
    }

    // MARK: - Helpers

    private func extractKeywords(from text: String) -> [String] {
        // Split on common separators and filter short words
        text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
    }

    private func parseDate(_ dateString: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: dateString)
    }
}
