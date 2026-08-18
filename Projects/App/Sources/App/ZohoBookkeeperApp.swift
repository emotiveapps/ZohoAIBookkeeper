import SwiftUI
import DesignSystem
import BookkeeperCore

@main
struct ZohoBookkeeperApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Theme.Colors.accent)
        }
    }
}
