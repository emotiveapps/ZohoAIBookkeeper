import SwiftUI
import DesignSystem
import Observation
import ZohoBooksClient
import BookkeeperCore

/// Per-year completeness report: blockers, per-account gaps, expense totals.
struct ReadinessView: View {
    let workspace: Workspace

    @Environment(\.dismiss) private var dismiss
    @State private var model: ReadinessModel?
    @State private var year = Calendar.current.component(.year, from: Date())

    private var yearOptions: [Int] {
        let current = Calendar.current.component(.year, from: Date())
        return Array((current - 3) ... current).reversed()
    }

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Colors.background)
            .navigationTitle("Tax Readiness")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Picker("Year", selection: $year) {
                        ForEach(yearOptions, id: \.self) { option in
                            Text(String(option)).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .task {
                if model == nil {
                    let newModel = ReadinessModel(workspace: workspace)
                    model = newModel
                    await newModel.run(year: year)
                }
            }
            .onChange(of: year) { _, newYear in
                Task { await model?.run(year: newYear) }
            }
        }
    }

    @ViewBuilder
    private func content(_ model: ReadinessModel) -> some View {
        switch model.state {
        case .idle:
            Color.clear

        case .running(let status):
            VStack(spacing: 12) {
                ProgressView()
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case .failed(let message):
            ContentUnavailableView {
                Label("Audit failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") {
                    Task { await model.run(year: year) }
                }
                .buttonStyle(.borderedProminent)
            }

        case .finished(let report):
            reportList(report)
        }
    }

    private func reportList(_ report: TaxReadinessReport) -> some View {
        List {
            Section {
                if report.blockers.isEmpty {
                    Label("No blockers — FY\(String(report.year)) looks ready to file", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Theme.Colors.success)
                } else {
                    ForEach(report.blockers, id: \.self) { blocker in
                        Label(blocker, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.Colors.error)
                            .font(.callout)
                    }
                }
            } header: {
                Text("Blockers")
            }

            Section("Accounts") {
                ForEach(report.accounts, id: \.accountId) { account in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(account.accountName)
                            Spacer()
                            if account.uncategorizedCount > 0 {
                                Text("\(account.uncategorizedCount) to review")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Theme.Colors.warning, in: Capsule())
                            } else {
                                Image(systemName: "checkmark.circle")
                                    .foregroundStyle(Theme.Colors.success)
                            }
                        }
                        Text("\(account.transactionCount) transactions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(Array(account.gaps.findings.enumerated()), id: \.offset) { _, finding in
                            Label(finding.summary, systemImage: "wifi.exclamationmark")
                                .font(.caption)
                                .foregroundStyle(finding.severity == .critical ? Theme.Colors.error : Theme.Colors.warning)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section {
                ForEach(report.expenses.byCategory, id: \.name) { category in
                    LabeledContent(category.name) {
                        Text(TaxReadinessReportFormatter.money(category.total))
                            .monospacedDigit()
                    }
                }
                LabeledContent("Total") {
                    Text(TaxReadinessReportFormatter.money(report.expenses.total))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                if report.expenses.missingVendorCount > 0 {
                    Label("\(report.expenses.missingVendorCount) expenses missing a vendor", systemImage: "person.crop.circle.badge.questionmark")
                        .font(.callout)
                        .foregroundStyle(Theme.Colors.warning)
                }
            } header: {
                Text("Expenses (\(report.expenses.count))")
            }

            if let inventory = report.inventory {
                Section {
                    ForEach(inventory.byAccount, id: \.name) { account in
                        LabeledContent(account.name) {
                            Text(TaxReadinessReportFormatter.money(account.total))
                                .monospacedDigit()
                        }
                    }
                } header: {
                    Text("Inventory / COGS purchases")
                } footer: {
                    Text("Asset purchases deducted via COGS when sold — not period expenses. Compute year-end COGS with the CLI's `cogs` command after your inventory count.")
                }
            }
        }
    }
}
