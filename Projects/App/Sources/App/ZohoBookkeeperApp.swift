import SwiftUI
import BookkeeperCore

@main
struct ZohoBookkeeperApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
    }
}
