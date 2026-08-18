import SwiftUI
import BookkeeperCore

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                SplashView()
            case .needsSetup:
                SetupView()
            case .ready(let workspace):
                HomeView(workspace: workspace)
            }
        }
        .task {
            await model.bootstrap()
        }
    }
}

#Preview("Needs setup") {
    RootView()
        .environment(AppModel(credentialsStore: InMemoryCredentialsStore()))
}
