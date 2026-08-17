import SwiftUI
import ZohoBooksClient
import BookkeeperCore

/// AI confidence pill, same thresholds as the CLI (≥80 green, ≥50 orange, else red).
struct ConfidenceBadge: View {
    let confidence: Int

    private var color: Color {
        confidence >= 80 ? AppTheme.Colors.success : confidence >= 50 ? AppTheme.Colors.warning : AppTheme.Colors.error
    }

    var body: some View {
        Text("\(confidence)%")
            .font(.caption.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
