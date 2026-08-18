import SwiftUI
import DesignSystem

/// A small copy-to-clipboard icon button; flips to a checkmark briefly after copying.
struct CopyButton: View {
    let text: String
    var accessibilityLabel = "Copy"

    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            withAnimation { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.footnote)
                .foregroundStyle(copied ? Theme.Colors.success : Theme.Colors.textSecondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}
