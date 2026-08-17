import SwiftUI
import Observation
import ZohoBooksClient
import BookkeeperCore

struct ReceiptRow: View {
    let record: ReceiptRecord

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.parsed?.vendor ?? record.source.subject ?? "Receipt")
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(record.parsed?.date ?? "no date")
                    Text(record.source.kind == "email" ? "✉️" : "📤")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let total = record.parsed?.total {
                Text(TaxReadinessReportFormatter.money(total))
                    .monospacedDigit()
            }
            if record.status == .matched {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppTheme.Colors.success)
            }
        }
    }
}
