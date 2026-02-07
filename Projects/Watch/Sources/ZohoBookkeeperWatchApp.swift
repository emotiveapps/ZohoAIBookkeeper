import SwiftUI
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

/// Simplified state for watchOS
@MainActor
final class WatchState: ObservableObject {
    @Published var pendingCount: Int = 0
    @Published var isLoading = false
    @Published var lastUpdated: Date?
    @Published var errorMessage: String?

    private var cacheService: CacheService?

    init() {
        do {
            cacheService = try CacheService()
        } catch {
            errorMessage = "Cache unavailable"
        }
    }

    func refresh() async {
        isLoading = true
        // In a full implementation, this would:
        // 1. Use Watch Connectivity to get data from iPhone
        // 2. Or make direct API calls if configured
        // For now, we'll show cached data
        lastUpdated = Date()
        isLoading = false
    }
}
