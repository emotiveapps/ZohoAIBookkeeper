#if os(watchOS)
import WidgetKit
import SwiftUI

/// Timeline provider for the complication
struct PendingCountProvider: TimelineProvider {
    func placeholder(in context: Context) -> PendingCountEntry {
        PendingCountEntry(isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (PendingCountEntry) -> Void) {
        // Return sample data for previews
        let entry = PendingCountEntry(pendingCount: 5)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PendingCountEntry>) -> Void) {
        // Reads the last count synced from the iPhone (see PhoneSyncReceiver,
        // which also reloads timelines whenever a new count arrives).
        let stored = PendingCountStorage.read()
        let currentDate = Date()
        let entry = PendingCountEntry(date: currentDate, pendingCount: stored.count)

        // Refresh every 15 minutes
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: currentDate)!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))

        completion(timeline)
    }
}
#endif
