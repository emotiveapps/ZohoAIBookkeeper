import SwiftUI
import DesignSystem
import BookkeeperCore

/// Credential editing lives one level deep so the keys — which in practice
/// never change — can't be clobbered from the main Settings screen.
struct CredentialsEditorView: View {
    @Environment(AppModel.self) private var model
    let workspace: Workspace
    /// Called after a successful save & reconnect (closes the Settings sheet —
    /// the sheet's workspace reference is stale once the app reconnects).
    let onSaved: () -> Void

    @State private var form = CredentialsFormModel()
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        Form {
            CredentialsFormSections(form: $form)

            if let saveError {
                Section {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.Colors.error)
                        .font(.callout)
                }
            }

            Section {
                Button {
                    Task { await saveAndReconnect() }
                } label: {
                    HStack {
                        Spacer()
                        if isSaving { ProgressView().padding(.trailing, 6) }
                        Text("Save & Reconnect").fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(isSaving || !form.isValid)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle("Credentials")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            form.apply(workspace.configuration)
        }
    }

    private func saveAndReconnect() async {
        isSaving = true
        saveError = nil
        saveError = await model.submitCredentials(form.configuration)
        isSaving = false
        if saveError == nil {
            onSaved()
        }
    }
}
