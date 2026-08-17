import SwiftUI

/// The app's design tokens — every color, type style, radius, and spacing
/// used by views lives here, so restyling the app is a one-file change.
/// Values are semantic ("success", "cardTitle"), never descriptive ("green"):
/// views say what they mean and this file decides how it looks.
enum AppTheme {
    /// Semantic colors. Backed by system colors today; brand palettes swap
    /// these values (ideally via asset-catalog colorsets for automatic
    /// dark-mode variants) without touching any view.
    enum Colors {
        /// Interactive elements and emphasis (buttons pick this up via the
        /// app accent color; use directly where tint doesn't reach).
        static let accent = Color.accentColor
        /// Positive state: matched receipts, completed accounts, checkmarks.
        static let success = Color.green
        /// Attention state: pending counts, finished-with-errors.
        static let warning = Color.orange
        /// Failure state: errors, broken connections, destructive hints.
        static let error = Color.red

        static let textPrimary = Color.primary
        static let textSecondary = Color.secondary

        /// Card surfaces on grouped screens.
        static let card = AnyShapeStyle(.background.secondary)
    }

    /// Type scale. Views reference roles, not fonts.
    enum Typography {
        /// Section/card headers ("AI suggestion").
        static let cardTitle = Font.subheadline.weight(.semibold)
        static let body = Font.body
        static let callout = Font.callout
        static let caption = Font.caption
        static let captionSecondary = Font.caption2
        /// Large numerals (amounts).
        static let amount = Font.system(.largeTitle, design: .rounded).weight(.bold)
        /// Compact counters ("2 of 107").
        static let counter = Font.footnote.monospacedDigit()
    }

    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
    }

    enum Spacing {
        static let tight: CGFloat = 4
        static let compact: CGFloat = 8
        static let standard: CGFloat = 12
        static let comfortable: CGFloat = 16
    }
}
