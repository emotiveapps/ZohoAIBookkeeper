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
#endif
