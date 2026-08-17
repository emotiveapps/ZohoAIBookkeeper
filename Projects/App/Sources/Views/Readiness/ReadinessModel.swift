import SwiftUI
import Observation
import ZohoBooksClient
import BookkeeperCore

/// Runs the tax-readiness audit for a chosen year and holds its state.
@MainActor
@Observable
final class ReadinessModel {
    enum State {
        case idle
        case running(String)
        case finished(TaxReadinessReport)
        case failed(String)
    }

    private(set) var state: State = .idle
    private let workspace: Workspace

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    func run(year: Int) async {
        state = .running("Starting…")
        do {
            let auditor = TaxReadinessAuditor(client: workspace.client)
            let report = try await auditor.audit(year: year) { [weak self] status in
                Task { @MainActor in
                    if let self, case .running = self.state {
                        self.state = .running(status)
                    }
                }
            }
            state = .finished(report)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
