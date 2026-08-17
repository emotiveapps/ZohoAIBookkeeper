import SwiftUI
import WatchConnectivity
import WidgetKit
import BookkeeperCore

@main
struct ZohoBookkeeperWatchApp: App {
    @StateObject private var watchState = WatchState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(watchState)
        }
    }
}
