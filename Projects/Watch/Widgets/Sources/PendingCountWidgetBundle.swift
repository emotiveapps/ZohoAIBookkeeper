#if os(watchOS)
import WidgetKit
import SwiftUI

/// Entry point of the watch widget extension.
@main
struct PendingCountWidgetBundle: WidgetBundle {
    var body: some Widget {
        PendingCountWidget()
    }
}
#endif
