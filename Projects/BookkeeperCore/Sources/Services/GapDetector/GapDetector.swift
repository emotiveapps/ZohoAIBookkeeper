import Foundation
import ZohoBooksClient


/// Detects bank-feed outages from transaction timelines. Pure logic — callers
/// fetch transactions (all statuses) and pass them in.
///
/// Method: compute the account's own cadence (median days between consecutive
/// transactions), then flag quiet stretches that are far outside that cadence.
/// Sparse accounts (long natural cadence) therefore need proportionally longer
/// silences before anything is flagged, and near-dormant accounts (< 3
/// transactions) are never flagged.
public struct GapDetector: Sendable {
    /// Minimum quiet days before anything can be flagged, regardless of cadence.
    public var minimumGapDays: Int
    /// A gap is flagged when it exceeds `cadenceMultiplier ×` the median interval.
    public var cadenceMultiplier: Double
    /// Gaps beyond `2 ×` the flag threshold are critical.

    public init(minimumGapDays: Int = 21, cadenceMultiplier: Double = 5) {
        self.minimumGapDays = minimumGapDays
        self.cadenceMultiplier = cadenceMultiplier
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")!
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    public static func parseDate(_ string: String) -> Date? {
        dateFormatter.date(from: string)
    }

    /// Analyze one account's transactions within [rangeStart, rangeEnd].
    public func analyze(
        accountId: String,
        accountName: String,
        transactions: [ZBBankTransaction],
        rangeStart: Date,
        rangeEnd: Date
    ) -> AccountGapReport {
        let dates = transactions
            .compactMap { Self.parseDate($0.date) }
            .filter { $0 >= rangeStart && $0 <= rangeEnd }
            .sorted()

        let weekly = Self.weeklyCounts(dates: dates, rangeStart: rangeStart, rangeEnd: rangeEnd)

        guard dates.count >= 3 else {
            return AccountGapReport(
                accountId: accountId,
                accountName: accountName,
                transactionCount: dates.count,
                firstDate: dates.first,
                lastDate: dates.last,
                medianIntervalDays: nil,
                weeklyCounts: weekly,
                findings: []
            )
        }

        let intervals = zip(dates.dropFirst(), dates).map { Self.days(from: $1, to: $0) }
        let median = Self.median(intervals)
        let flagThreshold = max(minimumGapDays, Int((Double(median) * cadenceMultiplier).rounded(.up)))
        let criticalThreshold = flagThreshold * 2

        var findings: [GapFinding] = []

        func severity(_ days: Int) -> GapFinding.Severity {
            days >= criticalThreshold ? .critical : .warning
        }

        // Internal silent windows
        for (previous, next) in zip(dates, dates.dropFirst()) {
            let gap = Self.days(from: previous, to: next)
            if gap >= flagThreshold {
                let cadence = median <= 1 ? "daily" : "every ~\(median)d"
                findings.append(GapFinding(
                    kind: .silentWindow,
                    severity: severity(gap),
                    start: previous,
                    end: next,
                    days: gap,
                    summary: "\(gap) days with no transactions (\(Self.format(previous)) → \(Self.format(next))); this account usually posts \(cadence)"
                ))
            }
        }

        // Late start: quiet lead-in to a range for an otherwise busy account
        if let first = dates.first {
            let lead = Self.days(from: rangeStart, to: first)
            if lead >= flagThreshold {
                findings.append(GapFinding(
                    kind: .lateStart,
                    severity: .warning,
                    start: rangeStart,
                    end: first,
                    days: lead,
                    summary: "No transactions for the first \(lead) days of the range (until \(Self.format(first))) — check whether the feed was connected"
                ))
            }
        }

        // Stale feed: quiet run-out at the end of the range
        if let last = dates.last {
            let tail = Self.days(from: last, to: rangeEnd)
            if tail >= flagThreshold {
                findings.append(GapFinding(
                    kind: .staleFeed,
                    severity: severity(tail),
                    start: last,
                    end: rangeEnd,
                    days: tail,
                    summary: "No transactions in the last \(tail) days of the range (since \(Self.format(last))) — the feed may have stopped"
                ))
            }
        }

        return AccountGapReport(
            accountId: accountId,
            accountName: accountName,
            transactionCount: dates.count,
            firstDate: dates.first,
            lastDate: dates.last,
            medianIntervalDays: median,
            weeklyCounts: weekly,
            findings: findings.sorted { $0.start < $1.start }
        )
    }

    // MARK: - Helpers

    static func days(from: Date, to: Date) -> Int {
        utcCalendar.dateComponents([.day], from: from, to: to).day ?? 0
    }

    static func median(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    static func weeklyCounts(dates: [Date], rangeStart: Date, rangeEnd: Date) -> [Int] {
        let totalDays = max(days(from: rangeStart, to: rangeEnd), 0)
        let weekCount = totalDays / 7 + 1
        var counts = [Int](repeating: 0, count: weekCount)
        for date in dates {
            let index = days(from: rangeStart, to: date) / 7
            if counts.indices.contains(index) {
                counts[index] += 1
            }
        }
        return counts
    }

    private static func format(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }
}

