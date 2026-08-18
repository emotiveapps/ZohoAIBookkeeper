import SwiftUI
import DesignSystem

/// Branded loading state shown while the app restores credentials and
/// connects to Zoho: the LFB badge on a white ground matching the logo's
/// own plate (navy in dark mode). Mirrors the system launch screen so any
/// handoff is seamless.
struct SplashView: View {
    var body: some View {
        ZStack {
            Color("LaunchBackground")
                .ignoresSafeArea()

            Image("LaunchLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 200, height: 200)

            ProgressView()
                .tint(Theme.Colors.accent)
                .offset(y: 150)
        }
    }
}

#Preview {
    SplashView()
}
