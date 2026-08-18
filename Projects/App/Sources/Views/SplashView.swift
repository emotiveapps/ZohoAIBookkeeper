import SwiftUI
import DesignSystem

/// Branded loading state shown while the app restores credentials and
/// connects to Zoho. Lays out identically to the system launch screen
/// (LaunchLogo centered on LaunchBackground) so the handoff is seamless —
/// the spinner is the only thing that fades in.
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
                .controlSize(.large)
                .tint(Theme.Colors.accent)
                .offset(y: 160)
        }
    }
}

#Preview {
    SplashView()
}
