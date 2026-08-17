import Foundation
import ZohoBooksClient

public enum ReceiptMatchOutcome: Sendable {
    /// Exactly one expense fits well enough to attach without asking.
    case confident(ZBExpense)
    /// More than one plausible expense — a human picks (`receipts attach`).
    case ambiguous([ZBExpense])
    /// Nothing fits yet — hold and retry after future syncs.
    case none
}

/// Matches a parsed receipt against candidate Zoho expenses. Pure logic.
///
/// Rules: an expense is a candidate when its amount matches the receipt total
/// (exactly, or within `percentTolerance` for tip/FX drift) and its date falls
/// within `dateWindowDays` of the receipt date (when the receipt has a date —
/// otherwise only exact-amount matches count). A single exact-amount candidate
/// is confident; a single tolerance-only candidate needs a vendor-name match
/// to be confident; anything else with candidates is ambiguous.
public struct ReceiptMatcher: Sendable {
    public var dateWindowDays: Int
    public var percentTolerance: Double

    public init(dateWindowDays: Int = 5, percentTolerance: Double = 0.02) {
        self.dateWindowDays = dateWindowDays
        self.percentTolerance = percentTolerance
    }

    public func match(receipt: ParsedReceipt, candidates: [ZBExpense]) -> ReceiptMatchOutcome {
        guard let total = receipt.total, total > 0 else { return .none }

        let receiptDate = receipt.date.flatMap { GapDetector.parseDate($0) }

        struct Scored {
            let expense: ZBExpense
            let exactAmount: Bool
            let vendorMatches: Bool
        }

        var scored: [Scored] = []
        for expense in candidates {
            let amount = expense.total ?? expense.amount ?? 0
            guard amount > 0 else { continue }

            let exact = abs(amount - total) < 0.01
            let withinTolerance = abs(amount - total) <= total * percentTolerance
            guard exact || withinTolerance else { continue }

            if let receiptDate {
                guard let expenseDate = expense.date.flatMap({ GapDetector.parseDate($0) }),
                      abs(GapDetector.days(from: receiptDate, to: expenseDate)) <= dateWindowDays else {
                    continue
                }
            } else if !exact {
                // No date to corroborate: only exact amounts qualify at all.
                continue
            }

            scored.append(Scored(
                expense: expense,
                exactAmount: exact,
                vendorMatches: Self.vendorsSimilar(receipt.vendor, expense.vendorName)
            ))
        }

        guard !scored.isEmpty else { return .none }

        // Prefer exact-amount candidates when any exist.
        let exactMatches = scored.filter(\.exactAmount)
        let pool = exactMatches.isEmpty ? scored : exactMatches

        if pool.count == 1, let only = pool.first {
            if only.exactAmount || only.vendorMatches {
                return .confident(only.expense)
            }
            return .ambiguous([only.expense])
        }

        // Multiple candidates: a unique vendor match wins; otherwise a human decides.
        let vendorMatches = pool.filter(\.vendorMatches)
        if vendorMatches.count == 1, let winner = vendorMatches.first, winner.exactAmount {
            return .confident(winner.expense)
        }
        return .ambiguous(pool.map(\.expense))
    }

    /// Loose vendor-name comparison: normalized token containment either way.
    static func vendorsSimilar(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let a = normalize(lhs), let b = normalize(rhs), !a.isEmpty, !b.isEmpty else {
            return false
        }
        return a.contains(b) || b.contains(a)
    }

    private static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let lowered = value.lowercased()
        let filtered = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(filtered))
    }
}
