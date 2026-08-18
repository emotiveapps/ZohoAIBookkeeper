#if os(watchOS)
import WidgetKit
import SwiftUI

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
