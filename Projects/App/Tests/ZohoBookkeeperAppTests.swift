import Testing
@testable import ZohoBookkeeperApp

@Suite("ZohoBookkeeperApp Tests")
struct ZohoBookkeeperAppTests {

    @Test("AppState initializes unconfigured")
    @MainActor
    func appStateInitializesUnconfigured() {
        let appState = AppState()
        #expect(!appState.isConfigured)
        #expect(!appState.isConnected)
    }
}
