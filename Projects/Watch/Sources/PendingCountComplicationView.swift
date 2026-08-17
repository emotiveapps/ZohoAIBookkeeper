#if os(watchOS)
import WidgetKit
import SwiftUI

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
#endif
