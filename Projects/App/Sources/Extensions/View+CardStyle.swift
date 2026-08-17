import SwiftUI

extension View {
    /// The app's standard card container: padded content on a card surface
    /// with the theme's medium corner radius.
    func cardStyle() -> some View {
        self
            .padding()
            .background(
                AppTheme.Colors.card,
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.medium)
            )
    }
}
