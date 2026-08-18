import SwiftUI
import DesignSystem

/// Branded loading state shown while the app restores credentials and
/// connects to Zoho: the circular LFB badge with an indeterminate progress
/// ring spinning around it (the logo is round — the ring completes it).
/// Uses the launch-screen assets so any handoff from the system launch
/// image is seamless.
struct SplashView: View {
    @State private var spinning = false

    private let logoSize: CGFloat = 200
    private let ringGap: CGFloat = 14
    private let ringWidth: CGFloat = 5

    var body: some View {
        ZStack {
            Color("LaunchBackground")
                .ignoresSafeArea()

            ZStack {
                Circle()
                    .stroke(Theme.Colors.accent.opacity(0.15), lineWidth: ringWidth)

                Circle()
                    .trim(from: 0, to: 0.22)
                    .stroke(
                        Theme.Colors.accent,
                        style: StrokeStyle(lineWidth: ringWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .animation(
                        .linear(duration: 1.1).repeatForever(autoreverses: false),
                        value: spinning
                    )

                Image("LaunchLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: logoSize, height: logoSize)
            }
            .frame(
                width: logoSize + 2 * (ringGap + ringWidth),
                height: logoSize + 2 * (ringGap + ringWidth)
            )
        }
        .onAppear { spinning = true }
    }
}

#Preview {
    SplashView()
}
