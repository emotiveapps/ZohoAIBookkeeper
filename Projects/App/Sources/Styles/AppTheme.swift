import SwiftUI

/// The app's design tokens — every color, type style, radius, and spacing
/// used by views lives here, so restyling the app is a one-file change.
/// Values are semantic ("success", "cardTitle"), never descriptive ("green"):
/// views say what they mean and this file decides how it looks.
enum AppTheme {
    /// Semantic colors, backed by the Lucky Frog Bricks palette
    /// (asset-catalog colorsets with light + dark variants; values from
    /// LF/Design's design-system survey: warm, progressive, playful).
    enum Colors {
        /// LFB orange — interactive elements and emphasis (buttons pick this
        /// up via the app accent color; use directly where tint doesn't reach).
        static let accent = Color("LFBPrimary")
        /// LFB green — matched receipts, completed accounts, checkmarks.
        static let success = Color("LFBGreen")
        /// Attention state: pending counts, finished-with-errors.
        static let warning = Color.orange
        /// Failure state: errors, broken connections, destructive hints.
        static let error = Color.red
        /// LFB purple — aspirational highlights (tax readiness, milestones).
        static let aspiration = Color("LFBPurple")

        static let textPrimary = Color.primary
        static let textSecondary = Color.secondary

        /// Warm off-white screen background (dark: system dark surface).
        static let background = Color("LFBBackground")
        /// Card surfaces over `background`.
        static let card = AnyShapeStyle(Color("LFBCard"))
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
