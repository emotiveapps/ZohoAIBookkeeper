import SwiftUI
import BookkeeperCore

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    let isInitialSetup: Bool

    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var accessToken = ""
    @State private var refreshToken = ""
    @State private var organizationId = ""
    @State private var region = "com"
    @State private var anthropicApiKey = ""

    @State private var isConnecting = false
    @State private var showingClearConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                // Zoho Configuration
                Section {
                    TextField("Client ID", text: $clientId)
                        .autocorrectionDisabled()
                        .textContentType(.username)

                    SecureField("Client Secret", text: $clientSecret)

                    SecureField("Access Token", text: $accessToken)

                    SecureField("Refresh Token", text: $refreshToken)

                    TextField("Organization ID", text: $organizationId)
                        .autocorrectionDisabled()

                    Picker("Region", selection: $region) {
                        Text("US (.com)").tag("com")
                        Text("EU (.eu)").tag("eu")
                        Text("India (.in)").tag("in")
                        Text("Australia (.au)").tag("au")
                    }
                } header: {
                    Text("Zoho Books")
                } footer: {
                    Text("Enter your Zoho Books API credentials. You can get these from the Zoho Developer Console.")
                }

                // Anthropic Configuration
                Section {
                    SecureField("API Key", text: $anthropicApiKey)
                } header: {
                    Text("Anthropic (Claude AI)")
                } footer: {
                    Text("Enter your Anthropic API key for AI-powered categorization suggestions.")
                }

                // Connection Status
                if appState.isConfigured {
                    Section("Status") {
                        HStack {
                            Text("Connection")
                            Spacer()
                            if appState.isConnected {
                                Label("Connected", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else if appState.connectionError != nil {
                                Label("Error", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                            } else {
                                Label("Not Connected", systemImage: "circle")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let error = appState.connectionError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        if appState.isConnected {
                            LabeledContent("Accounts") {
                                Text("\(appState.bankAccounts.count)")
                            }

                            LabeledContent("Categories") {
                                Text("\(appState.categories.count)")
                            }

                            LabeledContent("Vendors") {
                                Text("\(appState.vendors.count)")
                            }
                        }
                    }
                }

                // Actions
                Section {
                    Button {
                        Task {
                            await saveAndConnect()
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if isConnecting {
                                ProgressView()
                                    .padding(.trailing, 8)
                            }
                            Text(appState.isConfigured ? "Save & Reconnect" : "Connect")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(isConnecting || !isFormValid)

                    if appState.isConfigured {
                        Button("Clear Configuration", role: .destructive) {
                            showingClearConfirmation = true
                        }
                    }
                }
            }
            .navigationTitle(isInitialSetup ? "Setup" : "Settings")
            .onAppear {
                loadCurrentConfiguration()
            }
            .confirmationDialog(
                "Clear Configuration",
                isPresented: $showingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear", role: .destructive) {
                    appState.clearConfiguration()
                    clearForm()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove all saved credentials. You'll need to re-enter them to use the app.")
            }
        }
    }

    private var isFormValid: Bool {
        !clientId.isEmpty &&
        !clientSecret.isEmpty &&
        !accessToken.isEmpty &&
        !refreshToken.isEmpty &&
        !organizationId.isEmpty &&
        !anthropicApiKey.isEmpty
    }

    private func loadCurrentConfiguration() {
        if let zoho = appState.zohoConfig {
            clientId = zoho.clientId
            clientSecret = zoho.clientSecret
            accessToken = zoho.accessToken
            refreshToken = zoho.refreshToken
            organizationId = zoho.organizationId
            region = zoho.region
        }

        if let anthropic = appState.anthropicConfig {
            anthropicApiKey = anthropic.apiKey
        }
    }

    private func clearForm() {
        clientId = ""
        clientSecret = ""
        accessToken = ""
        refreshToken = ""
        organizationId = ""
        region = "com"
        anthropicApiKey = ""
    }

    private func saveAndConnect() async {
        isConnecting = true

        let zohoConfig = ZohoConfiguration(
            clientId: clientId,
            clientSecret: clientSecret,
            accessToken: accessToken,
            refreshToken: refreshToken,
            organizationId: organizationId,
            region: region
        )

        let anthropicConfig = AnthropicConfiguration(apiKey: anthropicApiKey)

        await appState.configure(zoho: zohoConfig, anthropic: anthropicConfig)
        await appState.connect()

        isConnecting = false
    }
}

#Preview("Initial Setup") {
    SettingsView(isInitialSetup: true)
        .environmentObject(AppState())
}

#Preview("Settings") {
    SettingsView(isInitialSetup: false)
        .environmentObject(AppState())
}
