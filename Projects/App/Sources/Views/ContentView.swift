import SwiftUI
import BookkeeperCore

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if appState.isConfigured {
                MainTabView()
            } else {
                SettingsView(isInitialSetup: true)
            }
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            DashboardView()
                .tabItem {
                    Label("Dashboard", systemImage: "chart.bar")
                }

            AccountListView()
                .tabItem {
                    Label("Accounts", systemImage: "building.columns")
                }

            SettingsView(isInitialSetup: false)
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
        .task {
            if !appState.isConnected {
                await appState.connect()
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
