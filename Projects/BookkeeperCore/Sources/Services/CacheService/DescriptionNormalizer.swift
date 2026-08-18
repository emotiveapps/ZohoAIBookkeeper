import Foundation

/// Collapses a raw bank-feed description into a stable lookup key so the same
/// recurring charge maps to the same key across statements: uppercased, with
/// digits and punctuation stripped (card references, dates, and store numbers
/// vary per transaction) and whitespace collapsed.
public enum DescriptionNormalizer {
    /// "INTEREST CHARGE:PURCHASES" -> "INTEREST CHARGE PURCHASES",
    /// "UNITED xxxxxxxxx1291" -> "UNITED XXXXXXXXX". Returns nil when too
    /// little text survives to be a meaningful key.
    public static func key(_ raw: String) -> String? {
        let cleaned = raw.uppercased()
            .map { $0.isLetter ? $0 : " " }
        let key = String(cleaned)
            .split(separator: " ")
            .joined(separator: " ")
        return key.count >= 4 ? key : nil
    }
}
