import SwiftUI
import BookkeeperCore

struct ContentView: View {
    @EnvironmentObject var watchState: WatchState

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Pending count display
                pendingCountView

                // Last updated
                if let lastUpdated = watchState.lastUpdated {
                    Text("Updated \(lastUpdated, style: .relative) ago")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Error message
                if let error = watchState.errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }

                // Refresh button
                Button {
                    Task {
                        await watchState.refresh()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(watchState.isLoading)
            }
            .padding()
            .navigationTitle("Bookkeeper")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            await watchState.refresh()
        }
    }

    private var pendingCountView: some View {
        VStack(spacing: 4) {
            if watchState.isLoading {
                ProgressView()
                    .frame(height: 60)
            } else {
                Text("\(watchState.pendingCount)")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(watchState.pendingCount > 0 ? .orange : .green)
            }

            Text("Pending")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(WatchState())
}
