#if os(watchOS)
import WidgetKit
import SwiftUI

/// Timeline entry for the complication
struct PendingCountEntry: TimelineEntry {
    let date: Date
    let pendingCount: Int
    let isPlaceholder: Bool

    init(date: Date = .now, pendingCount: Int = 0, isPlaceholder: Bool = false) {
        self.date = date
        self.pendingCount = pendingCount
        self.isPlaceholder = isPlaceholder
    }
}

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
        // In a full implementation, this would:
        // 1. Read from shared UserDefaults (App Group)
        // 2. Or fetch from Watch Connectivity cache
        // For now, return placeholder data

        let currentDate = Date()
        let entry = PendingCountEntry(date: currentDate, pendingCount: 0)

        // Refresh every 15 minutes
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: currentDate)!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))

        completion(timeline)
    }
}

/// Complication view
struct PendingCountComplicationView: View {
    @Environment(\.widgetFamily) var family
    let entry: PendingCountEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            circularView
        case .accessoryCorner:
            cornerView
        case .accessoryInline:
            inlineView
        case .accessoryRectangular:
            rectangularView
        default:
            circularView
        }
    }

    private var circularView: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Text("\(entry.pendingCount)")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(entry.pendingCount > 0 ? .orange : .green)
                Text("pending")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var cornerView: some View {
        Text("\(entry.pendingCount)")
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(entry.pendingCount > 0 ? .orange : .green)
            .widgetLabel {
                Text("Pending")
            }
    }

    private var inlineView: some View {
        Text("\(entry.pendingCount) pending transactions")
    }

    private var rectangularView: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Bookkeeper")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(entry.pendingCount)")
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundStyle(entry.pendingCount > 0 ? .orange : .green)
                Text("pending")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

/// WidgetKit widget definition
struct PendingCountWidget: Widget {
    let kind: String = "PendingCountWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PendingCountProvider()) { entry in
            PendingCountComplicationView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Pending Transactions")
        .description("Shows the number of pending bank transactions to categorize.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryInline,
            .accessoryRectangular
        ])
    }
}

#Preview(as: .accessoryCircular) {
    PendingCountWidget()
} timeline: {
    PendingCountEntry(pendingCount: 0)
    PendingCountEntry(pendingCount: 5)
    PendingCountEntry(pendingCount: 12)
}
#endif
