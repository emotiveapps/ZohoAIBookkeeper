import Foundation
import ZohoBooksClient

/// The slice of Zoho the history matcher needs. A protocol seam so the
/// matching logic is unit-testable without a network client.
public protocol VendorHistorySource: Sendable {
    /// Resolve a vendor name to its Zoho contact ID, or nil if unknown.
    func findVendorId(name: String) async throws -> String?
    /// All prior expenses recorded for a vendor.
    func fetchExpenses(vendorId: String) async throws -> [ZBExpense]
}
