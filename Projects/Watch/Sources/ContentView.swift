import SwiftUI
import BookkeeperCore

struct ContentView: View {
    @EnvironmentObject var watchState: WatchState

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                pendingCountView

                if let lastUpdated = watchState.lastUpdated {
                    Text("Updated \(lastUpdated, style: .relative) ago")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Open the iPhone app to sync")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button {
                    watchState.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .padding()
            .navigationTitle("Bookkeeper")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            watchState.refresh()
        }
    }

    private var pendingCountView: some View {
        VStack(spacing: 4) {
            Text("\(watchState.pendingCount)")
                .font(.system(size: 48, weight: .bold))
                .foregroundStyle(watchState.pendingCount > 0 ? .orange : .green)
                .contentTransition(.numericText())

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
