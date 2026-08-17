import SwiftUI
import BookkeeperCore


/// First-run onboarding: paste the CLI's config.json, or enter credentials by hand.
/// Credentials are verified against Zoho before being stored in the Keychain.
struct SetupView: View {
    @Environment(AppModel.self) private var model

    @State private var form = CredentialsFormModel()
    @State private var pastedJSON = ""
    @State private var importFeedback: ImportFeedback?
    @State private var isConnecting = false
    @State private var connectionError: String?

    enum ImportFeedback: Equatable {
        case success(categories: Int)
        case failure(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Connect the app to your Zoho Books organization and the Anthropic API. Credentials are stored only in your device's Keychain.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }

                importSection
                CredentialsFormSections(form: $form)

                if let connectionError {
                    Section {
                        Label(connectionError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }

                Section {
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack {
                            Spacer()
                            if isConnecting {
                                ProgressView().padding(.trailing, 6)
                            }
                            Text("Connect")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(isConnecting || !form.isValid)
                }
            }
            .navigationTitle("Setup")
            .interactiveDismissDisabled()
        }
    }

    private var importSection: some View {
        Section {
            TextField("Paste config.json here", text: $pastedJSON, axis: .vertical)
                .lineLimit(3 ... 6)
                .font(.system(.caption, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            Button("Import from JSON") {
                importJSON()
            }
            .disabled(pastedJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            switch importFeedback {
            case .success(let categories):
                Label(
                    categories > 0
                        ? "Imported, including \(categories) categories"
                        : "Imported",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
                .font(.callout)
            case .failure(let message):
                Label(message, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            case nil:
                EmptyView()
            }
        } header: {
            Text("Fastest: import the CLI config")
        } footer: {
            Text("AirDrop or copy the `config.json` used by the CLI, paste it above, and everything below fills in — including your custom category hierarchy.")
        }
    }

    private func importJSON() {
        do {
            let config = try ConfigLoader.parse(Data(pastedJSON.utf8))
            form.apply(config)
            importFeedback = .success(categories: config.categoryMapping?.allCategoryNames.count ?? 0)
        } catch {
            importFeedback = .failure("Couldn't read that JSON: \(error.localizedDescription)")
        }
    }

    private func connect() async {
        isConnecting = true
        connectionError = nil
        connectionError = await model.submitCredentials(form.configuration)
        isConnecting = false
    }
}

